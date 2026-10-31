import Foundation

enum Gamma: String, Sendable {
    case dlog = "D-Log"
    case dlogM = "D-Log M"
    case dlog2 = "D-Log2"
    case hlg = "HLG"
    case rec709 = "Rec.709"
    case unknown = "未知"
    var isLog: Bool { self == .dlog || self == .dlogM || self == .dlog2 }
}

struct MediaMetadata: Sendable {
    let gamma: Gamma
    let specification: String
    let duration: Double
    let rawOutput: String
}

enum MetadataReader {
    static func read(_ url: URL, ffmpeg: String, runner: ProcessRunner) async throws -> MediaMetadata {
        // ffmpeg -i normally exits nonzero when no output is specified; its stderr is the result.
        let (_, output) = try await runner.run(executable: ffmpeg, arguments: ["-hide_banner", "-i", url.path])
        let gammaText = capture("(?im)^\\s*(?:com\\.dji\\.camera\\.)?ColorGammaSxS\\s*:\\s*([^\\r\\n]+)", in: output)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = gammaText.lowercased().replacingOccurrences(of: "_", with: "-")
        let gamma: Gamma
        if normalized.contains("d-log2") || normalized.contains("dlog2") { gamma = .dlog2 }
        else if normalized.contains("d-log m") || normalized.contains("d-log-m") || normalized.contains("dlog-m") { gamma = .dlogM }
        else if normalized.contains("d-log") || normalized.contains("dlog") { gamma = .dlog }
        else if normalized.contains("hlg") { gamma = .hlg }
        else if normalized.contains("709") { gamma = .rec709 }
        else { gamma = .unknown }

        let durationText = capture("Duration:\\s*(\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?)", in: output) ?? ""
        let duration = seconds(durationText)
        let videoLine = output.components(separatedBy: .newlines).first { $0.contains("Video:") } ?? ""
        let resolution = capture("(?<!\\d)(\\d{3,5}x\\d{3,5})(?!\\d)", in: videoLine) ?? "—"
        let depth = capture("(?:yuv\\w*?(10|12|16)le|p(010|016)le)", in: videoLine).map { $0 == "010" ? "10" : ($0 == "016" ? "16" : $0) } ?? "8"
        let fps = capture("([0-9]+(?:\\.[0-9]+)?)\\s*fps", in: videoLine) ?? "—"
        return MediaMetadata(gamma: gamma, specification: "\(resolution) · \(depth) 位 · \(fps) fps", duration: duration, rawOutput: output)
    }

    static func seconds(_ value: String) -> Double {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
