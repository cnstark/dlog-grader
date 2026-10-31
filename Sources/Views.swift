import AppKit
import SwiftUI

struct GammaBadge: View {
    let gamma: Gamma
    var body: some View {
        Text(gamma.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(gamma.isLog ? .white : .secondary)
            .background(gamma.isLog ? color : Color.gray.opacity(0.15), in: Capsule())
    }
    private var color: Color {
        switch gamma {
        case .dlog2: .purple
        case .dlogM: .blue
        default: .orange
        }
    }
}

struct MediaInfoView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var detail: MediaItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("媒体信息").font(.title2.bold())
                Spacer()
                Button("手动导出视频…") { model.chooseManualFiles() }.disabled(!model.canStartManualExport)
                Button("立即扫描") { model.scanNow() }.disabled(!model.canStartScan)
                Button(model.processingActionTitle) { model.toggleProcessing() }
                    .disabled(!model.canToggleProcessing)
            }.padding()
            if let message = model.statusMessage {
                Text(message).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                Text("文件名").frame(maxWidth: .infinity, alignment: .leading)
                Text("来源").frame(width: 55, alignment: .leading)
                Text("曲线").frame(width: 110, alignment: .leading)
                Text("规格").frame(width: 225, alignment: .leading)
                Text("状态").frame(width: 290, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.source == .manual ? item.url.path : item.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.source == .manual ? "手动" : "监控").font(.caption).frame(width: 55, alignment: .leading)
                            GammaBadge(gamma: item.metadata.gamma).frame(width: 110, alignment: .leading)
                            Text(item.metadata.specification).font(.caption).frame(width: 225, alignment: .leading)
                            Text(item.status.label).font(.caption).foregroundStyle(statusColor(item.status)).lineLimit(2).help(item.status.label).frame(width: 290, alignment: .leading)
                        }
                        .padding(.horizontal).padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { detail = item }
                        Divider()
                    }
                }
            }
            if model.items.isEmpty {
                Text(model.scanning ? "正在扫描…" : "暂无媒体。可手动导出视频或扫描监视目录。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
            }
            Text("共 \(model.items.count) 个文件 · 双击查看完整 ffmpeg 信息")
                .font(.caption).foregroundStyle(.secondary).padding()
        }
        .frame(minWidth: 1030, minHeight: 450)
        .sheet(item: $detail) { item in
            VStack(alignment: .leading) {
                Text(item.name).font(.headline)
                ScrollView {
                    Text(item.metadata.rawOutput).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(8).background(Color(nsColor: .textBackgroundColor))
                HStack { Spacer(); Button("关闭") { detail = nil } }
            }.padding().frame(width: 700, height: 500)
        }
    }
    private func statusColor(_ status: MediaStatus) -> Color {
        if status.failed || status.sdr == .missingLUT { return .red }
        if status.exported { return .green }
        return .secondary
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("导出记录").font(.title2.bold()); Spacer(); Button("刷新") { model.refreshRecords() } }.padding()
            HStack {
                Text("时间").frame(width: 145, alignment: .leading)
                Text("文件").frame(maxWidth: .infinity, alignment: .leading)
                Text("曲线").frame(width: 90, alignment: .leading)
                Text("LUT").frame(width: 170, alignment: .leading)
                Text("耗时").frame(width: 75, alignment: .leading)
                Text("结果").frame(width: 45, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.records) { record in
                        HStack {
                            Text(record.date.formatted(date: .numeric, time: .shortened)).frame(width: 145, alignment: .leading)
                            Text(record.relativePath).lineLimit(1).help(record.relativePath).frame(maxWidth: .infinity, alignment: .leading)
                            Text(record.gamma).frame(width: 90, alignment: .leading)
                            Text(record.lut.hasPrefix("手动 · ") || record.lut == "HLG (shader)" ? record.lut : URL(fileURLWithPath: record.lut).lastPathComponent).lineLimit(1).help(record.lut).frame(width: 170, alignment: .leading)
                            Text(String(format: "%.0f 秒", record.elapsed)).frame(width: 75, alignment: .leading)
                            Text(record.success ? "✅" : "❌").help(record.error).frame(width: 45, alignment: .leading)
                        }.font(.caption).padding(.horizontal).padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            if model.records.isEmpty { Text("暂无导出记录").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding() }
        }.frame(minWidth: 850, minHeight: 400)
    }
}

struct ManualExportView: View {
    @ObservedObject var draft: ManualExportDraft
    let export: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("手动导出视频").font(.title2.bold())
            Text("已选文件（曲线正在异步检测）").font(.headline)
            HStack {
                Text("文件名").frame(maxWidth: .infinity, alignment: .leading)
                Text("曲线").frame(width: 100, alignment: .leading)
                Text("SDR").frame(width: 70, alignment: .leading)
                Text("HDR").frame(width: 100, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(draft.rows) { row in
                        HStack {
                            Text(row.url.lastPathComponent).lineLimit(1).help(row.url.path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.metadata?.gamma.rawValue ?? (row.error == nil ? "检测中…" : "读取失败"))
                                .frame(width: 100, alignment: .leading)
                            Text(row.metadata == nil ? "检测中…" : (row.metadata?.gamma.isLog == true ? "可导出" : "—"))
                                .frame(width: 70, alignment: .leading)
                            Text(row.metadata == nil ? "检测中…" : (row.metadata?.gamma == .dlog2 ? "可导出" : "不支持"))
                                .frame(width: 100, alignment: .leading)
                        }.font(.caption).padding(.vertical, 6)
                        if let error = row.error { Text(error).font(.caption).foregroundStyle(.red) }
                        if let metadata = row.metadata, !metadata.gamma.isLog {
                            Text("非 Log，将跳过").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }.frame(height: 210)
            HStack(spacing: 20) {
                Toggle("SDR (Rec.709)", isOn: $draft.sdrEnabled)
                Toggle("HDR (HLG)", isOn: $draft.hdrEnabled)
            }
            if draft.hdrEnabled { Text("HDR 仅适用于 D-Log2；其他曲线将跳过 HDR。")
                .font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("SDR LUT").frame(width: 70, alignment: .leading)
                Text(draft.lutURL?.lastPathComponent ?? "未选择 .cube 文件")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button("选择 LUT…") { chooseLUT() }
            }.disabled(!draft.sdrEnabled)
            HStack {
                Text("输出目录").frame(width: 70, alignment: .leading)
                Text(draft.outputURL?.path ?? "未选择")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button("选择目录…") { chooseOutput() }
            }
            if let issue = draft.issue { Text(issue).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: cancel)
                Button("导出", action: export).keyboardShortcut(.defaultAction).disabled(draft.issue != nil)
            }
        }.padding(20).frame(width: 670)
    }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        if panel.runModal() == .OK { draft.lutURL = panel.url }
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { draft.outputURL = panel.url }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Form {
            Section("监控目录自动处理 · 导出格式与目标") {
                Toggle("导出 SDR (Rec.709)", isOn: $settings.sdrEnabled)
                pathRow("SDR 导出目录", path: $settings.sdrExportPath, directory: true).disabled(!settings.sdrEnabled)
                Toggle("导出 HDR (HLG)", isOn: $settings.hdrEnabled)
                pathRow("HDR 导出目录", path: $settings.hdrExportPath, directory: true).disabled(!settings.hdrEnabled)
                pathRow("LUT 目录", path: $settings.lutPath, directory: true)
                Toggle("GPU 加速导出", isOn: $settings.useGPUExporter).disabled(!settings.sdrEnabled)
                Picker("并发数", selection: $settings.concurrency) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("监控目录自动处理 · 扫描与归档") {
                pathRow("监视目录", path: $settings.watchPath, directory: true)
                Toggle("归档原片", isOn: $settings.archiveEnabled)
                pathRow("归档目录", path: $settings.archivePath, directory: true).disabled(!settings.archiveEnabled)
                Toggle("自动扫描", isOn: $settings.autoScan)
                HStack { Text("扫描间隔（分钟）"); Spacer(); TextField("分钟", value: $settings.intervalMinutes, format: .number).frame(width: 70) }
            }
            Section("监控目录自动处理 · SDR LUT 偏好") {
                Picker("D-Log2 风格", selection: $settings.style) {
                    Text("vivid").tag("vivid"); Text("普通").tag("normal")
                }
                Picker("LUT 尺寸", selection: $settings.cubeSize) {
                    Text("size65").tag(65); Text("size33").tag(33)
                }
            }
            Section("监控目录自动处理 · 曲线 LUT（留空则自动匹配）") {
                pathRow("D-Log", path: $settings.dlogLUT, directory: false, cube: true)
                pathRow("D-Log M", path: $settings.dlogMLUT, directory: false, cube: true)
                pathRow("D-Log2", path: $settings.dlog2LUT, directory: false, cube: true)
            }
            Section("系统") {
                pathRow("ffmpeg 路径", path: $settings.ffmpegPath, directory: false, cube: false)
                Toggle("开机启动", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let error = settings.launchError { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 680, minHeight: 780)
    }

    private func pathRow(_ title: String, path: Binding<String>, directory: Bool, cube: Bool = false) -> some View {
        let issue = directory ? settings.directoryIssue(path.wrappedValue) : nil
        return HStack {
            Text(title).frame(width: 115, alignment: .leading)
            TextField(title, text: path)
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            Button("选择…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory
                panel.canChooseFiles = !directory
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                if cube { panel.allowedContentTypes = [.init(filenameExtension: "cube")!] }
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }
}
