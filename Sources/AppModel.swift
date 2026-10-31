import AppKit
import Foundation
import SwiftUI
import UserNotifications

enum ExportStage: Equatable {
    case disabled, pending, exporting(Int), done, failed(String), skipped(String), missingLUT, unsupported
    var needsWork: Bool { if case .pending = self { return true }; return false }
    var isDone: Bool { if case .done = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var label: String {
        switch self {
        case .disabled: return "关闭"
        case .pending: return "待处理"
        case let .exporting(percent): return "导出中 \(percent)%"
        case .done: return "完成"
        case let .failed(error): return "失败：\(error)"
        case let .skipped(reason): return "跳过：\(reason)"
        case .missingLUT: return "缺 LUT"
        case .unsupported: return "不支持"
        }
    }
}

struct MediaStatus: Equatable {
    var sdr: ExportStage
    var hdr: ExportStage
    var archive: String = ""
    var canProcess: Bool { sdr.needsWork || hdr.needsWork || archive == "待归档" }
    var failed: Bool { sdr.isFailed || hdr.isFailed }
    var exported: Bool { sdr.isDone || hdr.isDone }
    var label: String { "SDR \(sdr.label) · HDR \(hdr.label)" + (archive.isEmpty ? "" : " · \(archive)") }
}

struct MediaItem: Identifiable {
    let id: String
    let url: URL
    let relativePath: String
    let metadata: MediaMetadata
    var status: MediaStatus
    var name: String { url.lastPathComponent }
}

private struct ExportJob: Sendable {
    let id: String
    let hdr: Bool
    let outputPath: String
}

@MainActor final class AppModel: ObservableObject {
    let settings = SettingsStore()
    let history: HistoryStore?
    @Published var items: [MediaItem] = []
    @Published var records: [ExportRecord] = []
    @Published var scanning = false
    @Published var processing = false
    @Published var currentExportName: String?
    @Published var currentProgress = 0
    @Published var message: String?
    private var scanTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var currentRunner: ProcessRunner?
    private var activeRunners: [UUID: ProcessRunner] = [:]
    private var activeGPUExporters: [UUID: MetalLUTExporter] = [:]
    private var activeProgress: [UUID: (name: String, percent: Int)] = [:]
    private var lastScan = Date.distantPast

    init() {
        do { history = try HistoryStore(); records = history?.all() ?? [] }
        catch { history = nil; message = error.localizedDescription }
        settings.onOptionsChange = { [weak self] in self?.refreshEligibility() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var pendingCount: Int { items.filter { $0.status.canProcess }.count }
    var exportedCount: Int { items.filter { $0.status.exported }.count }
    var failedCount: Int { items.filter { $0.status.failed }.count }
    var actionablePendingCount: Int { pendingCount }
    var processingActionTitle: String { processing ? "停止处理" : "开始处理 (\(actionablePendingCount))" }
    var statusMessage: String? { settings.requiredDirectoryIssue ?? message }
    var canToggleProcessing: Bool { processing || (!scanning && settings.requiredDirectoryIssue == nil && actionablePendingCount > 0) }
    var isActive: Bool { settings.autoScan }

    func scanNow() { startScan(autoProcess: false) }
    func startAutomaticScan() { startScan(autoProcess: true) }
    private func startScan(autoProcess: Bool) {
        guard !scanning, !processing else { return }
        if let issue = settings.requiredDirectoryIssue {
            message = issue
            lastScan = Date()
            return
        }
        scanning = true
        scanTask = Task {
            let completed = await performScan()
            if autoProcess && completed && settings.autoScan && !Task.isCancelled { startProcessing() }
        }
    }
    func cancelScan() {
        scanTask?.cancel()
        processingTask?.cancel()
        currentRunner?.terminate()
        for runner in activeRunners.values { runner.terminate() }
        for exporter in activeGPUExporters.values { exporter.cancel() }
    }
    func toggleProcessing() {
        if processing { cancelScan() } else { startProcessing() }
    }
    private func startProcessing() {
        if let issue = settings.requiredDirectoryIssue { message = issue; return }
        guard !scanning, !processing, actionablePendingCount > 0 else { return }
        processing = true
        processingTask = Task { await performPendingItems() }
    }
    func toggleAutoScan() {
        settings.autoScan.toggle()
        if !settings.autoScan { cancelScan() } else { startScan(autoProcess: true) }
    }
    func timerTick() {
        guard settings.autoScan, !scanning, !processing else { return }
        if Date().timeIntervalSince(lastScan) >= Double(max(1, settings.intervalMinutes)) * 60 { startScan(autoProcess: true) }
    }
    func refreshRecords() { records = history?.all() ?? [] }

    private func output(for relative: String, root: String) -> URL {
        let name = (relative as NSString).pathExtension.lowercased() == "mov"
            ? (relative as NSString).deletingPathExtension + ".MP4" : relative
        return URL(fileURLWithPath: root).standardizedFileURL.appendingPathComponent(name)
    }
    private func status(for item: MediaItem) -> MediaStatus {
        let archive = settings.archiveEnabled ? URL(fileURLWithPath: settings.archivePath).standardizedFileURL : nil
        let sdrOutput = output(for: item.relativePath, root: settings.sdrExportPath)
        let hdrOutput = output(for: item.relativePath, root: settings.hdrExportPath)
        let sdr: ExportStage
        if !settings.sdrEnabled || !item.metadata.gamma.isLog { sdr = .disabled }
        else if history?.hasSuccess(outputPath: sdrOutput.path, hdr: false, archiveRoot: archive) == true { sdr = .done }
        else if settings.selectedLUT(for: item.metadata.gamma) == nil { sdr = .missingLUT }
        else { sdr = .pending }
        let hdr: ExportStage
        if !settings.hdrEnabled || !item.metadata.gamma.isLog { hdr = .disabled }
        else if item.metadata.gamma != .dlog2 { hdr = .unsupported }
        else if history?.hasSuccess(outputPath: hdrOutput.path, hdr: true, archiveRoot: archive) == true { hdr = .done }
        else { hdr = .pending }
        let archiveState = settings.archiveEnabled && item.metadata.gamma.isLog && sdr != .missingLUT ? "待归档" : ""
        return MediaStatus(sdr: sdr, hdr: hdr, archive: archiveState)
    }
    private func refreshEligibility() {
        guard !processing else { return }
        for index in items.indices where !items[index].status.failed {
            items[index].status = status(for: items[index])
        }
        if settings.requiredDirectoryIssue == nil && message == "请先在设置中配置目录" { message = nil }
        if !settings.sdrEnabled && !settings.hdrEnabled && !settings.archiveEnabled {
            message = "无可执行导出：请开启 SDR、HDR 或归档原片"
        } else if message == "无可执行导出：请开启 SDR、HDR 或归档原片" { message = nil }
    }
    private func setStage(_ id: String, hdr: Bool, stage: ExportStage) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if hdr { items[index].status.hdr = stage } else { items[index].status.sdr = stage }
    }
    private func setArchive(_ id: String, _ text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status.archive = text
    }

    private func performScan() async -> Bool {
        defer {
            scanning = false
            scanTask = nil
            currentRunner = nil
            currentExportName = nil
            lastScan = Date()
            refreshRecords()
        }
        items = []
        message = nil
        if let issue = settings.requiredDirectoryIssue { message = issue; return false }
        let watch = URL(fileURLWithPath: settings.watchPath).standardizedFileURL
        let roots = [settings.archivePath, settings.sdrExportPath, settings.hdrExportPath]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard !roots.contains(where: { watch.path == $0.path || watch.path.hasPrefix($0.path + "/") }) else {
            message = "监视目录不能位于归档或导出目录中"
            return false
        }
        guard FileManager.default.fileExists(atPath: settings.ffmpegPath) else {
            message = "找不到 ffmpeg：\(settings.ffmpegPath)"
            return false
        }
        do {
            let files = try await Scanner.files(in: watch, excluding: roots)
            for file in files {
                try Task.checkCancellation()
                guard let relative = Scanner.relativePath(of: file, in: watch) else { continue }
                let runner = ProcessRunner()
                currentRunner = runner
                let metadata: MediaMetadata
                do { metadata = try await MetadataReader.read(file, ffmpeg: settings.ffmpegPath, runner: runner) }
                catch {
                    if Task.isCancelled { break }
                    currentRunner = nil
                    let fallback = MediaMetadata(gamma: .unknown, specification: "—", duration: 0, rawOutput: error.localizedDescription)
                    items.append(MediaItem(id: file.path, url: file, relativePath: relative, metadata: fallback,
                                           status: MediaStatus(sdr: .failed(error.localizedDescription), hdr: .disabled)))
                    continue
                }
                currentRunner = nil
                var item = MediaItem(id: file.path, url: file, relativePath: relative, metadata: metadata,
                                     status: MediaStatus(sdr: .disabled, hdr: .disabled))
                item.status = status(for: item)
                items.append(item)
            }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
            return false
        }
        refreshEligibility()
        return !Task.isCancelled
    }

    private func performPendingItems() async {
        defer {
            processing = false
            processingTask = nil
            activeRunners.removeAll()
            activeGPUExporters.removeAll()
            activeProgress.removeAll()
            currentExportName = nil
            refreshRecords()
        }
        let selected = items.filter { $0.status.canProcess }
        var pendingJobs = selected.flatMap { item -> [ExportJob] in
            [(false, item.status.sdr), (true, item.status.hdr)].compactMap { hdr, stage in
                guard stage.needsWork else { return nil }
                let root = hdr ? settings.hdrExportPath : settings.sdrExportPath
                return ExportJob(id: item.id, hdr: hdr, outputPath: output(for: item.relativePath, root: root).path)
            }
        }
        var remaining = Dictionary(pendingJobs.map { ($0.id, 1) }, uniquingKeysWith: +)
        for item in selected where remaining[item.id] == nil {
            if Task.isCancelled { return }
            archiveIfReady(item.id)
        }
        var activePaths: Set<String> = []
        do {
            try await withThrowingTaskGroup(of: ExportJob.self) { group in
                func submitNext() {
                    guard !Task.isCancelled,
                          let index = pendingJobs.firstIndex(where: { !activePaths.contains($0.outputPath) }) else { return }
                    let job = pendingJobs.remove(at: index)
                    activePaths.insert(job.outputPath)
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.exportOne(job)
                        return job
                    }
                }
                for _ in 0..<min(3, max(1, settings.concurrency)) { submitNext() }
                while let job = try await group.next() {
                    activePaths.remove(job.outputPath)
                    remaining[job.id, default: 1] -= 1
                    if remaining[job.id] == 0 { archiveIfReady(job.id) }
                    submitNext()
                }
            }
        } catch {
            // Cancellation propagates to every child in the group. Each child
            // restores its own stage to pending and removes its partial output.
        }
    }

    private func updateExportDisplay() {
        if let active = activeProgress.values.first {
            currentExportName = active.name
            currentProgress = active.percent
        } else {
            currentExportName = nil
            currentProgress = 0
        }
    }

    private func exportOne(_ job: ExportJob) async throws {
        try Task.checkCancellation()
        let id = job.id
        let hdr = job.hdr
        guard let item = items.first(where: { $0.id == id }) else { return }
        let file = item.url
        let relative = item.relativePath
        let output = URL(fileURLWithPath: job.outputPath)
        let stage = hdr ? item.status.hdr : item.status.sdr
        guard stage.needsWork else { return }
        let lut = hdr ? nil : settings.selectedLUT(for: item.metadata.gamma)
        if !hdr && lut == nil {
            setStage(id, hdr: hdr, stage: .missingLUT)
            return
        }
        let ffmpeg = settings.ffmpegPath
        let useGPUExporter = settings.useGPUExporter
        let jobID = UUID()
        defer {
            activeRunners[jobID] = nil
            activeGPUExporters[jobID] = nil
            activeProgress[jobID] = nil
            updateExportDisplay()
        }
        // A completed first export may be reused after a later export failed,
        // even though the original has not yet moved into the archive.
        if history?.hasSuccess(outputPath: output.path, hdr: hdr) == true {
            setStage(id, hdr: hdr, stage: .done)
            return
        }
        if FileManager.default.fileExists(atPath: output.path) {
            setStage(id, hdr: hdr, stage: .skipped("目标已存在"))
            return
        }
        let start = Date()
        let lutRecord = hdr ? "HLG (shader)" : (lut?.lastPathComponent ?? "")
        activeProgress[jobID] = (file.lastPathComponent, 0)
        updateExportDisplay()
        setStage(id, hdr: hdr, stage: .exporting(0))
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let progress: @Sendable (Int) -> Void = { [weak self] percent in
                Task { @MainActor [weak self] in
                    guard let self, self.activeProgress[jobID] != nil,
                          let current = self.items.first(where: { $0.id == id }) else { return }
                    let currentStage = hdr ? current.status.hdr : current.status.sdr
                    guard case .exporting = currentStage else { return }
                    self.activeProgress[jobID] = (file.lastPathComponent, percent)
                    self.updateExportDisplay()
                    self.setStage(id, hdr: hdr, stage: .exporting(percent))
                }
            }
            if hdr || useGPUExporter {
                let gpu = MetalLUTExporter()
                activeGPUExporters[jobID] = gpu
                do {
                    let mode: MetalLUTExporter.Mode = hdr ? .hlg : .sdr(lut!)
                    try await gpu.export(input: file, output: output, mode: mode, ffmpeg: ffmpeg, progress: progress)
                } catch {
                    try Task.checkCancellation()
                    if hdr { throw error }
                    message = "GPU 导出失败，已改用 ffmpeg：\(error.localizedDescription)"
                    try? FileManager.default.removeItem(at: output)
                    let runner = ProcessRunner()
                    activeRunners[jobID] = runner
                    try await Exporter.export(input: file, output: output, lut: lut!, ffmpeg: ffmpeg,
                                              duration: item.metadata.duration, runner: runner, progress: progress)
                }
                activeGPUExporters[jobID] = nil
            } else {
                let runner = ProcessRunner()
                activeRunners[jobID] = runner
                try await Exporter.export(input: file, output: output, lut: lut!, ffmpeg: ffmpeg,
                                          duration: item.metadata.duration, runner: runner, progress: progress)
            }
            try Task.checkCancellation()
            activeRunners[jobID] = nil
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            history?.insert(relativePath: relative, gamma: item.metadata.gamma.rawValue, lut: lutRecord,
                            elapsed: Date().timeIntervalSince(start), success: true, outputPath: output.path, fileSize: size, error: "")
            setStage(id, hdr: hdr, stage: .done)
            notify(title: hdr ? "HDR 导出完成" : "SDR 导出完成", body: output.lastPathComponent)
        } catch {
            activeRunners[jobID] = nil
            activeGPUExporters[jobID] = nil
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled {
                setStage(id, hdr: hdr, stage: .pending)
                throw CancellationError()
            }
            history?.insert(relativePath: relative, gamma: item.metadata.gamma.rawValue, lut: lutRecord,
                            elapsed: Date().timeIntervalSince(start), success: false, outputPath: output.path, fileSize: 0,
                            error: error.localizedDescription)
            setStage(id, hdr: hdr, stage: .failed(error.localizedDescription))
            notify(title: "导出失败", body: "\(file.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    private func archiveIfReady(_ id: String) {
        guard !Task.isCancelled, settings.archiveEnabled,
              let item = items.first(where: { $0.id == id }), item.status.archive == "待归档" else { return }
        func complete(_ stage: ExportStage) -> Bool {
            switch stage {
            case .done, .disabled, .unsupported: return true
            default: return false
            }
        }
        guard complete(item.status.sdr), complete(item.status.hdr) else { return }
        let file = item.url
        let relative = item.relativePath
        let archived = URL(fileURLWithPath: settings.archivePath).standardizedFileURL.appendingPathComponent(relative)
        guard !FileManager.default.fileExists(atPath: archived.path) else {
            setArchive(item.id, "归档跳过：目标已存在")
            return
        }
        do {
            try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: archived)
            setArchive(item.id, "已归档")
        } catch {
            setArchive(item.id, "归档失败：\(error.localizedDescription)")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
