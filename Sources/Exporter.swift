import Foundation

enum Exporter {
    static func export(input: URL, output: URL, lut: URL, ffmpeg: String, duration: Double, runner: ProcessRunner, progress: @escaping @Sendable (Int) -> Void) async throws {
        // Escape only for ffmpeg's filter parser. The process arguments themselves are never shell-interpolated.
        let escaped = lut.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
        let filter = "lut3d=file='\(escaped)'"
        let args = ["-hide_banner", "-y", "-i", input.path, "-vf", filter,
                    "-pix_fmt", "p010le", "-c:v", "hevc_videotoolbox", "-b:v", "50M",
                    "-tag:v", "hvc1", "-c:a", "copy",
                    "-movflags", "use_metadata_tags", "-metadata", "com.dji.camera.ColorGammaSxS=Rec.709", output.path]
        let buffer = ProgressBuffer(duration: duration, callback: progress)
        let (status, text) = try await runner.run(executable: ffmpeg, arguments: args) { chunk in buffer.consume(chunk) }
        if status != 0 { throw RunnerError.failed(status, text) }
        progress(100)
    }
}

private final class ProgressBuffer: @unchecked Sendable {
    let duration: Double
    let callback: @Sendable (Int) -> Void
    let lock = NSLock()
    var tail = ""
    var last = -1
    init(duration: Double, callback: @escaping @Sendable (Int) -> Void) {
        self.duration = duration; self.callback = callback
    }
    func consume(_ chunk: String) {
        guard duration > 0 else { return }
        lock.lock()
        tail = String((tail + chunk).suffix(1024))
        let matches = try? NSRegularExpression(pattern: "time=(\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?)").matches(in: tail, range: NSRange(tail.startIndex..., in: tail))
        var value: Int?
        if let match = matches?.last, let range = Range(match.range(at: 1), in: tail) {
            value = min(99, max(0, Int(MetadataReader.seconds(String(tail[range])) / duration * 100)))
        }
        if let value, value != last { last = value } else { value = nil }
        lock.unlock()
        if let value { callback(value) }
    }
}
