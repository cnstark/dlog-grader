import Foundation

enum Scanner {
    static func files(in root: URL, excluding directories: [URL]) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let rootPath = root.standardizedFileURL.path
            guard fm.fileExists(atPath: rootPath) else { return [URL]() }
            let excludedPaths = directories.map { $0.standardizedFileURL.path }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [URL]() }
            var results: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                if excludedPaths.contains(where: { url.standardizedFileURL.path == $0 || url.standardizedFileURL.path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard ext == "mp4" || ext == "mov" else { continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { results.append(url) }
            }
            return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }.value
    }

    static func relativePath(of file: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}
