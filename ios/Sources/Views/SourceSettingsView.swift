import SwiftUI
import UIKit

/// 第三方音源管理：新增、编辑、开关、排序、导入导出、测试。
struct SourceSettingsView: View {
    @ObservedObject private var store = SourceStore.shared
    @State private var editing: ThirdPartySource?
    @State private var isCreatingTemplate = false
    @State private var isCreatingScript = false
    @State private var isImporting = false
    @State private var isExporting = false

    var body: some View {
        List {
            Section {
                if store.sources.isEmpty {
                    EmptyStateView(icon: "antenna.radiowaves.left.and.right",
                                   title: "还没有添加音源",
                                   message: "官方接口够用时可以不配；遇到 VIP 或无版权再加")
                } else {
                    ForEach(store.sources) { source in
                        SourceRow(source: source) {
                            store.setEnabled(!source.enabled, id: source.id)
                        } onEdit: {
                            editing = source
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.06))
                    }
                    .onMove { offsets, destination in
                        var list = store.sources
                        list.move(fromOffsets: offsets, toOffset: destination)
                        store.reorder(list)
                    }
                    .onDelete { offsets in
                        // 先取快照：边遍历边删会让后面的下标全部前移
                        let targets = offsets.map { store.sources[$0] }
                        for target in targets {
                            _ = store.remove(id: target.id)
                        }
                    }
                }
            } header: {
                Text("音源列表")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
            } footer: {
                Text("从上到下不是硬性顺序：所有启用的音源会并发请求，谁先返回可用地址就用谁。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Section {
                Button {
                    isCreatingTemplate = true
                } label: {
                    Label("新增接口模板音源", systemImage: "link.badge.plus")
                }
                Button {
                    isCreatingScript = true
                } label: {
                    Label("新增 JS 脚本音源", systemImage: "curlybraces")
                }
                Button {
                    isImporting = true
                } label: {
                    Label("从 JSON 导入", systemImage: "square.and.arrow.down")
                }
                Button {
                    isExporting = true
                } label: {
                    Label("导出全部音源", systemImage: "square.and.arrow.up")
                }
                .disabled(store.sources.isEmpty)
            } header: {
                Text("添加")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppStyle.background)
        .navigationTitle("第三方音源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .sheet(item: $editing) { source in
            SourceEditorView(source: source)
        }
        .sheet(isPresented: $isCreatingTemplate) {
            SourceEditorView(source: SourceFormTemplate.templateForm)
        }
        .sheet(isPresented: $isCreatingScript) {
            SourceEditorView(source: SourceFormTemplate.scriptForm)
        }
        .sheet(isPresented: $isImporting) {
            SourceImportView()
        }
        .sheet(isPresented: $isExporting) {
            SourceExportView()
        }
    }
}

// MARK: - 列表行

private struct SourceRow: View {
    let source: ThirdPartySource
    let onToggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isScript ? "curlybraces.square" : "link")
                .font(.system(size: 15))
                .foregroundStyle(source.enabled ? AppStyle.accent : AppStyle.tertiaryText)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
                if !source.isUsable {
                    Text(source.isScript ? "脚本内容为空" : "配置不完整，启用后不会生效")
                        .font(.system(size: 10))
                        .foregroundStyle(AppStyle.like)
                }
            }

            Spacer(minLength: 4)

            Toggle("", isOn: Binding(get: { source.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(AppStyle.accent)

            Button(action: onEdit) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppStyle.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        if source.isScript { return "JS 脚本 · 音质 \(source.quality)" }
        let host = URL(string: source.template)?.host ?? "地址无效"
        return "\(host) · 音质 \(source.quality)"
    }
}

// MARK: - 编辑表单

struct SourceEditorView: View {
    @State private var draft: ThirdPartySource
    @State private var headersText: String
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var isSuccess = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SourceStore.shared

    private let isNew: Bool

    init(source: ThirdPartySource) {
        _draft = State(initialValue: source)
        _headersText = State(initialValue: Self.serialize(source.headers))
        isNew = !SourceStore.shared.sources.contains { $0.id == source.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    Picker("类型", selection: $draft.kind) {
                        ForEach(ThirdPartySource.Kind.allCases, id: \.rawValue) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("默认音质", selection: $draft.quality) {
                        // 导入的音源可能带着列表之外的值，补一个同名 tag 避免 Picker 失配
                        ForEach(Self.qualityOptions(including: draft.quality), id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                }

                if draft.kind == .template {
                    Section {
                        TextField("请求地址，如 https://example.com/song?id={id}&br={quality}",
                                  text: $draft.template,
                                  axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, design: .monospaced))
                        TextField("地址字段，如 data.url|url", text: $draft.urlPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("接口模板")
                    } footer: {
                        Text("占位符：{id} {name} {artist} {keyword} {source} {quality} {apiKey}")
                            .font(.system(size: 11))
                    }
                } else {
                    Section {
                        TextEditor(text: $draft.script)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 220)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("脚本内容")
                    } footer: {
                        Text("支持 lx.on('request', ...) 或 module.exports.musicUrl / MusicPlugin.getMusicUrl。脚本里用 lx.request 发请求，返回播放地址字符串即可。")
                            .font(.system(size: 11))
                    }
                }

                Section {
                    TextField("每行一条：Key=Value", text: $headersText, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("请求头")
                } footer: {
                    Text("特殊键：apiKey（密钥，多个用逗号分隔）、apiKeys、source（限定平台，网易云填 wy）、quality。")
                        .font(.system(size: 11))
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            Text("测试解析")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting || !draft.isUsable)

                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 12))
                            .foregroundStyle(isSuccess ? AppStyle.accent : AppStyle.like)
                    }
                } header: {
                    Text("测试")
                } footer: {
                    Text("用一首固定的测试歌跑一遍完整解析流程，确认配置可用。")
                        .font(.system(size: 11))
                }
            }
            .navigationTitle(isNew ? "新增音源" : "编辑音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var updated = draft
        updated.headers = Self.parseHeaders(headersText)
        updated.name = updated.name.trimmingCharacters(in: .whitespaces)
        store.upsert(updated)
        dismiss()
    }

    private func runTest() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        var probe = draft
        probe.headers = Self.parseHeaders(headersText)
        probe.enabled = true
        let song = Song(id: "wy:150208236", title: "晴天", artist: "周杰伦", source: .netease, neteaseID: 150208236)

        if let audio = await SourceResolver.thirdPartyURL(sources: [probe],
                                                          song: song,
                                                          quality: .standard,
                                                          excludedHosts: []) {
            isSuccess = true
            testResult = "成功：\(audio.sourceName) · \(audio.quality.title)\n\(audio.url.absoluteString)"
        } else {
            isSuccess = false
            testResult = """
            没解析到地址。逐项检查：
            · 地址模板能不能直接打开，{id} 是否已替换成 150208236
            · 「地址字段」和返回内容对不对得上（返回是 JSON 就填 data.url|url 这类）
            · 音质档位（128k / 320k / flac）服务端是否支持
            · apiKey 是否有效，或是否需要 Referer / UA
            """
        }
    }

    static func qualityOptions(including current: String) -> [String] {
        let base = ["128k", "320k", "flac"]
        return base.contains(current) ? base : base + [current]
    }

    static func serialize(_ headers: [String: String]) -> String {
        headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    static func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let index = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<index]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

// MARK: - 导入 / 导出

struct SourceImportView: View {
    @State private var text = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SourceStore.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("粘贴音源配置 JSON，支持单条对象、数组，或带 sources 字段的对象。字段也可用 url 代替 template。")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.accent)
                }
                Spacer()
            }
            .padding(16)
            .background(AppStyle.background)
            .navigationTitle("导入音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入") { importSources() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func importSources() {
        let parsed = SourceStore.parseImport(text)
        guard !parsed.isEmpty else {
            message = "没解析出音源，检查 JSON 格式"
            return
        }
        for source in parsed { store.upsert(source) }
        dismiss()
    }
}

struct SourceExportView: View {
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SourceStore.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppStyle.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("复制到剪贴板", systemImage: "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(AppStyle.accent)
            }
            .padding(16)
            .background(AppStyle.background)
            .navigationTitle("导出音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { text = store.exportJSON() ?? "[]" }
        }
    }
}
