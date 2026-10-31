import AVFoundation
import CoreVideo
import Foundation
import Metal
import VideoToolbox

private enum MetalExportError: LocalizedError {
    case unavailable(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): reason
        }
    }
}

private struct LUTParameters {
    var domainMin: SIMD3<Float>
    var domainMax: SIMD3<Float>
    var size: UInt32
}

private struct CubeLUT {
    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let values: [SIMD4<Float>]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw MetalExportError.failed("LUT 文件不是 UTF-8：\(url.lastPathComponent)")
        }
        var cubeSize: Int?
        var minValue = SIMD3<Float>(repeating: 0)
        var maxValue = SIMD3<Float>(repeating: 1)
        var entries: [SIMD4<Float>] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("TITLE") { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let key = fields.first else { continue }
            switch key.uppercased() {
            case "LUT_3D_SIZE":
                guard fields.count == 2, let n = Int(fields[1]), n >= 2, n <= 256 else {
                    throw MetalExportError.failed("无效的 LUT_3D_SIZE")
                }
                cubeSize = n
                entries.reserveCapacity(n * n * n)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard fields.count == 4, let r = Float(fields[1]), let g = Float(fields[2]), let b = Float(fields[3]),
                      r.isFinite, g.isFinite, b.isFinite else {
                    throw MetalExportError.failed("无效的 LUT DOMAIN")
                }
                if key.uppercased() == "DOMAIN_MIN" { minValue = SIMD3(r, g, b) }
                else { maxValue = SIMD3(r, g, b) }
            case "LUT_1D_SIZE":
                throw MetalExportError.failed("不支持 1D LUT")
            default:
                if fields.count == 3, let r = Float(fields[0]), let g = Float(fields[1]), let b = Float(fields[2]),
                   r.isFinite, g.isFinite, b.isFinite {
                    entries.append(SIMD4(r, g, b, 1))
                } else if !key.hasPrefix("LUT_") {
                    throw MetalExportError.failed("无效的 LUT 数据：\(line)")
                }
            }
        }
        guard let n = cubeSize, entries.count == n * n * n, all(maxValue .> minValue) else {
            throw MetalExportError.failed("LUT 数据数量或 DOMAIN 范围无效")
        }
        size = n
        domainMin = minValue
        domainMax = maxValue
        values = entries // .cube stores red fastest, matching Metal 3D texture x-fastest order.
    }
}

final class MetalLUTExporter: @unchecked Sendable {
    enum Interpolation { case trilinear, tetrahedral }
    enum Mode { case sdr(URL), hlg }

    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var remuxRunner: ProcessRunner?

    func cancel() {
        lock.lock()
        cancelled = true
        let activeReader = reader
        let activeWriter = writer
        let activeRemux = remuxRunner
        lock.unlock()
        activeReader?.cancelReading()
        activeWriter?.cancelWriting()
        activeRemux?.terminate()
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    func export(input: URL, output: URL, mode: Mode, ffmpeg: String, progress: @escaping @Sendable (Int) -> Void) async throws {
        let videoURL = output.deletingLastPathComponent().appendingPathComponent(".dlog-\(UUID().uuidString)-video.mp4")
        let finalURL = output.deletingLastPathComponent().appendingPathComponent(".dlog-\(UUID().uuidString)-final.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: finalURL)
        }
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try self.exportVideo(input: input, output: videoURL, mode: mode, progress: progress)
            }.value
            try checkCancellation()
            let asset = AVURLAsset(url: input)
            let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
            let runner = ProcessRunner()
            lock.withLock { remuxRunner = runner }
            var args = ["-hide_banner", "-y", "-i", videoURL.path]
            if hasAudio { args += ["-i", input.path] }
            args += ["-map", "0:v:0"]
            if hasAudio { args += ["-map", "1:a"] }
            let gammaTag: String
            switch mode { case .sdr: gammaTag = "Rec.709"; case .hlg: gammaTag = "Rec.2100 HLG" }
            args += ["-c", "copy", "-movflags", "+faststart+use_metadata_tags",
                     "-metadata", "com.dji.camera.ColorGammaSxS=\(gammaTag)", finalURL.path]
            let (status, log) = try await runner.run(executable: ffmpeg, arguments: args)
            lock.withLock { remuxRunner = nil }
            guard status == 0 else { throw MetalExportError.failed("封装失败：\(log.suffix(500))") }
            try checkCancellation()
            try FileManager.default.moveItem(at: finalURL, to: output)
            progress(100)
        } onCancel: {
            self.cancel()
        }
    }

    private func exportVideo(input: URL, output: URL, mode: Mode, progress: @escaping @Sendable (Int) -> Void) throws {
        try checkCancellation()
        let cube: CubeLUT?
        let shaderName: String
        let functionName: String
        switch mode {
        case .sdr(let lut): cube = try CubeLUT(url: lut); shaderName = "LUTKernel"; functionName = "applyLUT"
        case .hlg: cube = nil; shaderName = "HDRKernel"; functionName = "applyHLG"
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw MetalExportError.unavailable("无法创建 Metal 设备") }
        let library: MTLLibrary
        if let bundleURL = Bundle.main.url(forResource: shaderName, withExtension: "metallib") {
            library = try device.makeLibrary(URL: bundleURL)
        } else if let sourceURL = Bundle.main.url(forResource: shaderName, withExtension: "metal") {
            library = try device.makeLibrary(source: String(contentsOf: sourceURL, encoding: .utf8), options: nil)
        } else { throw MetalExportError.unavailable("找不到 \(shaderName) Metal shader") }
        guard let function = library.makeFunction(name: functionName) else { throw MetalExportError.unavailable("找不到 \(functionName) kernel") }
        let pipeline = try device.makeComputePipelineState(function: function)
        var lutTexture: MTLTexture?
        if let cube {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba32Float
            descriptor.width = cube.size
            descriptor.height = cube.size
            descriptor.depth = cube.size
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw MetalExportError.unavailable("无法分配 3D LUT 纹理") }
            cube.values.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake3D(0, 0, 0, cube.size, cube.size, cube.size), mipmapLevel: 0, slice: 0,
                                withBytes: bytes.baseAddress!, bytesPerRow: cube.size * MemoryLayout<SIMD4<Float>>.stride,
                                bytesPerImage: cube.size * cube.size * MemoryLayout<SIMD4<Float>>.stride)
            }
            lutTexture = texture
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalExportError.unavailable("无法创建 Metal 纹理缓存") }
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .video).first else { throw MetalExportError.failed("源文件没有视频轨") }
        let size = track.naturalSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { throw MetalExportError.failed("源视频尺寸无效") }
        let pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                                         kCVPixelBufferWidthKey as String: width,
                                         kCVPixelBufferHeightKey as String: height,
                                         kCVPixelBufferMetalCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw MetalExportError.failed("无法读取 10-bit RGB 视频帧") }
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let compression: [String: Any] = [AVVideoAverageBitRateKey: 50_000_000,
                                           AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
        let colorProperties: [String: Any]
        switch mode {
        case .sdr:
            colorProperties = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .hlg:
            colorProperties = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                               AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
                                       AVVideoWidthKey: width, AVVideoHeightKey: height,
                                       AVVideoCompressionPropertiesKey: compression,
                                       AVVideoColorPropertiesKey: colorProperties]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = track.preferredTransform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(writerInput) else { throw MetalExportError.failed("无法配置 HEVC Main10 编码器") }
        writer.add(writerInput)
        lock.lock()
        self.reader = reader
        self.writer = writer
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        defer {
            lock.lock()
            self.reader = nil
            self.writer = nil
            lock.unlock()
        }
        guard reader.startReading(), writer.startWriting() else {
            throw MetalExportError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "视频管线无法启动")
        }
        writer.startSession(atSourceTime: .zero)
        let duration = CMTimeGetSeconds(asset.duration)
        var frameCount = 0
        while let sample = readerOutput.copyNextSampleBuffer() {
            try checkCancellation()
            guard let sourcePixel = CMSampleBufferGetImageBuffer(sample) else { throw MetalExportError.failed("解码帧缺少像素缓冲区") }
            while !writerInput.isReadyForMoreMediaData {
                try checkCancellation()
                if writer.status == .failed { throw MetalExportError.failed(writer.error?.localizedDescription ?? "编码失败") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { throw MetalExportError.failed("无法取得编码像素池") }
            var destinationPixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationPixel) == kCVReturnSuccess,
                  let destinationPixel else { throw MetalExportError.failed("无法分配输出像素缓冲区") }
            let sourceTexture = try makeTexture(cache: cache, pixel: sourcePixel, width: width, height: height)
            let destinationTexture = try makeTexture(cache: cache, pixel: destinationPixel, width: width, height: height)
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw MetalExportError.failed("无法创建 Metal 命令")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(destinationTexture, index: 1)
            if let cube, let lutTexture {
                var parameters = LUTParameters(domainMin: cube.domainMin, domainMax: cube.domainMax, size: UInt32(cube.size))
                encoder.setTexture(lutTexture, index: 2)
                encoder.setBytes(&parameters, length: MemoryLayout<LUTParameters>.stride, index: 0)
            }
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw MetalExportError.failed(command.error?.localizedDescription ?? "Metal LUT 运算失败") }
            guard adaptor.append(destinationPixel, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) else {
                throw MetalExportError.failed(writer.error?.localizedDescription ?? "写入视频帧失败")
            }
            frameCount += 1
            if duration.isFinite && duration > 0 {
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                progress(min(99, max(0, Int(time / duration * 100))))
            } else if frameCount == 1 { progress(1) }
        }
        try checkCancellation()
        guard reader.status == .completed else { throw MetalExportError.failed(reader.error?.localizedDescription ?? "视频读取失败") }
        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut { try checkCancellation() }
        guard writer.status == .completed else { throw MetalExportError.failed(writer.error?.localizedDescription ?? "视频写入失败") }
    }

    private func makeTexture(cache: CVMetalTextureCache, pixel: CVPixelBuffer, width: Int, height: Int) throws -> MTLTexture {
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, .bgr10a2Unorm,
                                                                width, height, 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            throw MetalExportError.unavailable("ARGB2101010 像素缓冲区无法映射为 Metal 纹理（状态 \(status)）")
        }
        return texture
    }
}
