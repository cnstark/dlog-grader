import AppKit
import Combine
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var mediaWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var manualWindow: NSPanel?
    private var timer: Timer?
    private var progressObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onManualDialogRequested = { [weak self] draft in self?.showManualDialog(draft) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.filters", accessibilityDescription: "DLogGrader")
        statusItem.button?.imagePosition = .imageLeading
        progressObserver = model.$currentProgress.combineLatest(model.$currentExportName)
            .sink { [weak self] percent, name in self?.updateStatusItem(name: name, percent: percent) }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.timerTick(); self?.updateStatusItem() }
        }
        if model.settings.autoScan && model.settings.scanDirectoryIssue == nil { model.startAutomaticScan() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusItem()
        menu.removeAllItems()
        let state = model.settings.autoScan ? "监视中" : "已暂停"
        let summary = NSMenuItem(title: "\(state) · 待处理 \(model.pendingCount) · 已导出 \(model.exportedCount) · 失败 \(model.failedCount)", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        let manual = item("手动导出视频…", #selector(manualExport), "")
        manual.isEnabled = model.canStartManualExport
        menu.addItem(manual)
        menu.addItem(.separator())
        menu.addItem(summary)
        if let message = model.statusMessage {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let scan = item("立即扫描", #selector(scan), "r")
        scan.isEnabled = model.canStartScan
        menu.addItem(scan)
        let processing = item(model.processingActionTitle, #selector(toggleProcessing), "")
        processing.isEnabled = model.canToggleProcessing
        menu.addItem(processing)
        let automatic = item("自动扫描", #selector(toggleAutomatic), "")
        automatic.state = model.settings.autoScan ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())
        menu.addItem(item("查看媒体信息…", #selector(showMedia), ""))
        menu.addItem(item("导出记录…", #selector(showHistory), ""))
        menu.addItem(.separator())
        let openWatch = item("打开监视目录", #selector(openWatch), "")
        openWatch.isEnabled = model.settings.directoryIssue(model.settings.watchPath) == nil
        menu.addItem(openWatch)
        let openArchive = item("打开归档目录", #selector(openArchive), "")
        openArchive.isEnabled = model.settings.directoryIssue(model.settings.archivePath) == nil
        menu.addItem(openArchive)
        menu.addItem(item("设置…", #selector(showSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatusItem() {
        updateStatusItem(name: model.currentExportName, percent: model.currentProgress)
    }

    private func updateStatusItem(name: String?, percent: Int) {
        if let name { statusItem.button?.title = "\(name) \(percent)%"; statusItem.button?.toolTip = name }
        else { statusItem.button?.title = ""; statusItem.button?.toolTip = "DLogGrader" }
    }

    @objc private func scan() { model.scanNow() }
    @objc private func manualExport() { model.chooseManualFiles() }
    private func showManualDialog(_ draft: ManualExportDraft) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 670, height: 570),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "手动导出视频"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ManualExportView(draft: draft, export: { [weak self] in
            self?.model.confirmManualExport(draft)
            self?.manualWindow?.close()
        }, cancel: { [weak self] in self?.manualWindow?.close() }))
        manualWindow = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === manualWindow else { return }
        model.cancelManualDialog()
        manualWindow = nil
    }
    @objc private func toggleProcessing() { model.toggleProcessing() }
    @objc private func toggleAutomatic() { model.toggleAutoScan() }
    @objc private func openWatch() { NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.watchPath)) }
    @objc private func openArchive() { NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.archivePath)) }
    @objc private func showMedia() {
        if mediaWindow == nil { mediaWindow = makeWindow("媒体信息", content: MediaInfoView(model: model, settings: model.settings), size: NSSize(width: 900, height: 520)) }
        mediaWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showHistory() {
        model.refreshRecords()
        if historyWindow == nil { historyWindow = makeWindow("导出记录", content: HistoryView(model: model), size: NSSize(width: 900, height: 480)) }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = makeWindow("设置", content: SettingsView(settings: model.settings), size: NSSize(width: 720, height: 720)) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func makeWindow<V: View>(_ title: String, content: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.center()
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        return window
    }
    @objc private func quit() {
        model.cancelScan()
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) { model.cancelScan() }
}

@MainActor @main struct Main {
    private static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
