import Foundation
import SwiftUI
import ServiceManagement

@MainActor final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var watchPath: String { didSet { save(); onOptionsChange?() } }
    @Published var archivePath: String { didSet { save(); onOptionsChange?() } }
    @Published var sdrExportPath: String { didSet { save(); onOptionsChange?() } }
    @Published var hdrExportPath: String { didSet { save(); onOptionsChange?() } }
    @Published var archiveEnabled: Bool { didSet { save(); onOptionsChange?() } }
    @Published var sdrEnabled: Bool { didSet { save(); onOptionsChange?() } }
    @Published var hdrEnabled: Bool { didSet { save(); onOptionsChange?() } }
    @Published var lutPath: String { didSet { save(); onOptionsChange?() } }
    @Published var ffmpegPath: String { didSet { save() } }
    @Published var autoScan: Bool { didSet { save() } }
    @Published var useGPUExporter: Bool { didSet { save() } }
    @Published var concurrency: Int { didSet { save() } }
    var onOptionsChange: (() -> Void)?
    @Published var intervalMinutes: Int { didSet { save() } }
    @Published var style: String { didSet { save() } }
    @Published var cubeSize: Int { didSet { save() } }
    @Published var dlogLUT: String { didSet { save() } }
    @Published var dlogMLUT: String { didSet { save() } }
    @Published var dlog2LUT: String { didSet { save() } }
    @Published var launchAtLogin: Bool = false
    @Published var launchError: String?

    init() {
        watchPath = defaults.string(forKey: "watchPath") ?? ""
        archivePath = defaults.string(forKey: "archivePath") ?? ""
        sdrExportPath = defaults.string(forKey: "sdrExportPath") ?? ""
        hdrExportPath = defaults.string(forKey: "hdrExportPath") ?? ""
        archiveEnabled = defaults.object(forKey: "archiveEnabled") as? Bool ?? true
        sdrEnabled = defaults.object(forKey: "sdrEnabled") as? Bool ?? true
        hdrEnabled = defaults.object(forKey: "hdrEnabled") as? Bool ?? true
        lutPath = defaults.string(forKey: "lutPath") ?? ""
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? "/opt/homebrew/bin/ffmpeg"
        autoScan = defaults.object(forKey: "autoScan") as? Bool ?? true
        useGPUExporter = defaults.object(forKey: "useGPUExporter") as? Bool ?? true
        concurrency = min(3, max(1, defaults.object(forKey: "concurrency") as? Int ?? 2))
        intervalMinutes = max(1, defaults.object(forKey: "intervalMinutes") as? Int ?? 5)
        style = defaults.string(forKey: "style") ?? "vivid"
        cubeSize = defaults.object(forKey: "cubeSize") as? Int ?? 65
        dlogLUT = defaults.string(forKey: "dlogLUT") ?? ""
        dlogMLUT = defaults.string(forKey: "dlogMLUT") ?? ""
        dlog2LUT = defaults.string(forKey: "dlog2LUT") ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        defaults.set(watchPath, forKey: "watchPath")
        defaults.set(archivePath, forKey: "archivePath")
        defaults.set(sdrExportPath, forKey: "sdrExportPath")
        defaults.set(hdrExportPath, forKey: "hdrExportPath")
        defaults.set(archiveEnabled, forKey: "archiveEnabled")
        defaults.set(sdrEnabled, forKey: "sdrEnabled")
        defaults.set(hdrEnabled, forKey: "hdrEnabled")
        defaults.set(lutPath, forKey: "lutPath")
        defaults.set(ffmpegPath, forKey: "ffmpegPath")
        defaults.set(autoScan, forKey: "autoScan")
        defaults.set(useGPUExporter, forKey: "useGPUExporter")
        defaults.set(min(3, max(1, concurrency)), forKey: "concurrency")
        defaults.set(max(1, intervalMinutes), forKey: "intervalMinutes")
        defaults.set(style, forKey: "style")
        defaults.set(cubeSize, forKey: "cubeSize")
        defaults.set(dlogLUT, forKey: "dlogLUT")
        defaults.set(dlogMLUT, forKey: "dlogMLUT")
        defaults.set(dlog2LUT, forKey: "dlog2LUT")
    }

    func directoryIssue(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未配置" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue else { return "目录不存在" }
        return nil
    }

    var requiredDirectoryIssue: String? {
        if directoryIssue(watchPath) != nil { return "请先在设置中配置目录" }
        if archiveEnabled && directoryIssue(archivePath) != nil { return "请先在设置中配置目录" }
        if sdrEnabled && directoryIssue(sdrExportPath) != nil { return "请先在设置中配置目录" }
        if hdrEnabled && directoryIssue(hdrExportPath) != nil { return "请先在设置中配置目录" }
        return nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = error.localizedDescription
        }
    }

    func selectedLUT(for gamma: Gamma) -> URL? {
        let explicit: String
        switch gamma {
        case .dlog: explicit = dlogLUT
        case .dlogM: explicit = dlogMLUT
        case .dlog2: explicit = dlog2LUT
        default: return nil
        }
        if !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard directoryIssue(lutPath) == nil else { return nil }
        let folder = URL(fileURLWithPath: lutPath)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let cubes = files.filter { $0.pathExtension.lowercased() == "cube" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let matches = cubes.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            switch gamma {
            case .dlog2: return name.contains("d-log2") || name.contains("dlog2")
            case .dlogM: return name.contains("d-log m") || name.contains("dlog-m") || name.contains("d-log-m")
            case .dlog: return (name.contains("d-log") || name.contains("dlog")) && !name.contains("d-log2") && !name.contains("dlog2") && !name.contains("d-log m") && !name.contains("dlog-m") && !name.contains("d-log-m")
            default: return false
            }
        }
        if gamma == .dlog2 {
            let styleMatches = matches.filter { style == "vivid" ? $0.lastPathComponent.lowercased().contains("vivid") : !$0.lastPathComponent.lowercased().contains("vivid") }
            let sizeText = "size\(cubeSize)"
            return styleMatches.first { $0.lastPathComponent.lowercased().contains(sizeText) }
                ?? styleMatches.first { $0.lastPathComponent.lowercased().contains("\(cubeSize)") }
                ?? styleMatches.first ?? matches.first
        }
        return matches.first
    }
}
