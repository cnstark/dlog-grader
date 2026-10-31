import Foundation

enum RunnerError: LocalizedError {
    case cancelled
    case failed(Int32, String)
    var errorDescription: String? {
        switch self {
        case .cancelled: "操作已取消"
        case let .failed(code, output): "ffmpeg 退出码 \(code)：\(output.suffix(500))"
        }
    }
}

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func terminate() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func run(executable: String, arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> (Int32, String) {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try self.execute(executable: executable, arguments: arguments, onOutput: onOutput)
            }.value
        } onCancel: {
            self.terminate()
        }
    }

    private func execute(executable: String, arguments: [String], onOutput: (@Sendable (String) -> Void)?) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw RunnerError.cancelled }
        process = task
        lock.unlock()
        defer {
            lock.lock()
            process = nil
            lock.unlock()
        }
        try task.run()
        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            data.append(chunk)
            onOutput?(String(decoding: chunk, as: UTF8.self))
        }
        task.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw RunnerError.cancelled }
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
