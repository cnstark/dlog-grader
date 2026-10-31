import Foundation

@main struct GPUSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            fputs("用法: GPUTest 输入视频 输出MP4 LUT.cube|--hdr ffmpeg路径\n", stderr)
            exit(2)
        }
        let args = CommandLine.arguments
        let exporter = MetalLUTExporter()
        do {
            let mode: MetalLUTExporter.Mode = args[3] == "--hdr" ? .hlg : .sdr(URL(fileURLWithPath: args[3]))
            try await exporter.export(input: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]),
                                      mode: mode, ffmpeg: args[4]) { percent in
                print("\(percent)%")
            }
        } catch {
            fputs("GPU 导出失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
