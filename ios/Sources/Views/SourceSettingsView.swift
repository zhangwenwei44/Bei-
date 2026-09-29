import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 第三方音源管理：新增、编辑、开关、排序、导入导出、测试。
struct SourceSettingsView: View {
    @ObservedObject private var store = SourceStore.shared
    /// 整个页面只挂一个 sheet，用这个枚举决定内容。
    ///
    /// 之前这里是六个并列的 .sheet 修饰器。在 iOS 16 上同一个 view 挂多个
    /// .sheet(isPresented:) 只有一个可靠生效，其余会静默呈现失败——用户侧
    /// 表现就是「点从文件导入，什么都没发生」。
    private enum Sheet: Identifiable {
        case editor(ThirdPartySource)
        case newTemplate
        case newScript
        case paste
        case export
        case pickFile

        var id: String {
            switch self {
            case .editor(let source): return "editor-\(source.id)"
            case .newTemplate: return "newTemplate"
            case .newScript: return "newScript"
            case .paste: return "paste"
            case .export: return "export"
            case .pickFile: return "pickFile"
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var importMessage: String?
    @State private var isImportingFiles = false

    var body: some View {
        List {
            if importMessage != nil || isImportingFiles {
                Section {
                    importBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                if store.sources.isEmpty {
                    // 音源列表为空 = 所有歌都放不出来。这里必须直说，
                    // 之前只写「官方接口够用时可以不配」，会让人以为是正常状态。
                    VStack(spacing: 10) {
                        EmptyStateView(icon: "antenna.radiowaves.left.and.right",
                                       title: "还没有添加音源",
                                       message: presets.isEmpty
                                        ? "这版安装包不带内置音源。用下面「添加」区的「从文件导入」或「从剪贴板导入」，把音源 .js 脚本加进来即可"
                                        : "下面有内置音源，点一下就能用")
                        if !presets.isEmpty {
                            Button {
                                let added = BundledSources.installMissing()
                                importMessage = added > 0
                                    ? "已添加 \(added) 个内置音源，打开它们的开关即可播放"
                                    : "内置音源已经都在列表里了"
                            } label: {
                                Text("一键添加全部内置音源")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .foregroundStyle(AppStyle.onAccent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ForEach(store.sources) { source in
                        SourceRow(source: source) {
                            store.setEnabled(!source.enabled, id: source.id)
                        } onEdit: {
                            sheet = .editor(source)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(AppStyle.stroke)
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

            // 安装包里没有任何内置脚本时整块隐藏：只留一个空标题会让人
            // 以为包坏了。现在的 CI 包就是不带音源的，这是预期状态。
            if !presets.isEmpty {
                Section {
                    ForEach(presets) { preset in
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(AppStyle.gold)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(preset.displayName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(AppStyle.primaryText)
                                    Text(preset.version)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(AppStyle.tertiaryText)
                                }
                                Text(presetLine(preset))
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if isInstalled(preset) {
                                Button("已添加") { }
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppStyle.accent)
                                    .disabled(true)
                            } else {
                                Button {
                                    add(preset)
                                } label: {
                                    Text("添加")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("内置音源")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                } footer: {
                    Text("随包发布，不用再选文件。第三方脚本由原作者提供服务，可能随时失效；仅供个人学习使用。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
            }

            Section {
                Button {
                    sheet = .newTemplate
                } label: {
                    Label("新增接口模板音源", systemImage: "link.badge.plus")
                }
                Button {
                    sheet = .newScript
                } label: {
                    Label("新增 JS 脚本音源", systemImage: "curlybraces")
                }
                Button {
                    sheet = .pickFile
                } label: {
                    Label("从文件导入", systemImage: "doc.badge.plus")
                }
                Button {
                    importFromAppDirectory()
                } label: {
                    Label("从 App 目录导入", systemImage: "folder")
                }
                Button {
                    sheet = .paste
                } label: {
                    Label("粘贴内容导入", systemImage: "text.alignleft")
                }
                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                }
                Button {
                    sheet = .export
                } label: {
                    Label("导出全部音源", systemImage: "square.and.arrow.up")
                }
                .disabled(store.sources.isEmpty)
            } header: {
                Text("添加")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.tertiaryText)
            } footer: {
                Text("「从文件导入」用系统选择器挑任意位置的文件。\n「从 App 目录导入」读的是本 App 自己的 Documents/Imports，用 iTunes/Finder/SSH 把音源文件放进去即可，最不容易出问题。\n也可以在「文件」App 里点分享，选择本 App 直接导入。")
                    .font(.system(size: 11))
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
        .sheet(item: $sheet) { item in
            switch item {
            case .editor(let source):
                SourceEditorView(source: source)
            case .newTemplate:
                SourceEditorView(source: SourceFormTemplate.templateForm)
            case .newScript:
                SourceEditorView(source: SourceFormTemplate.scriptForm)
            case .paste:
                SourceImportView()
            case .export:
                SourceExportView()
            case .pickFile:
                DocumentPicker(types: Self.importableTypes) { urls in
                    sheet = nil
                    Task { await importFromFiles(urls) }
                } onCancel: {
                    sheet = nil
                }
            }
        }
        // 从「文件」App 分享过来的音源
        .onOpenURL { url in
            Log.info("音源导入", "收到分享进来的 URL: \(url.absoluteString)")
            Task { await importFromFiles([url]) }
        }
    }

    /// 导入结果直接显示在列表顶部。
    ///
    /// 之前用 alert 展示，选完文件经常「没反应」：alert 和同层的 sheet 抢呈现，
    /// 加上弹窗被系统丢弃就什么都看不到。页内横幅不会被吞。
    @ViewBuilder
    private var importBanner: some View {
        if let importMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: importSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(importSucceeded ? AppStyle.accent : AppStyle.like)
                Text(importMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    withAnimation { self.importMessage = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        } else if isImportingFiles {
            HStack(spacing: 10) {
                ProgressView().tint(AppStyle.accent)
                Text("正在读取并解析文件…")
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                Spacer()
            }
            .padding(12)
            .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var importSucceeded: Bool {
        importMessage?.hasPrefix("成功") == true || importMessage?.hasPrefix("导入") == true
    }

    // MARK: - 内置音源

    private var presets: [BundledSources.Preset] {
        BundledSources.available
    }

    private func isInstalled(_ preset: BundledSources.Preset) -> Bool {
        store.sources.contains { $0.name == preset.displayName }
    }

    private func presetLine(_ preset: BundledSources.Preset) -> String {
        var parts: [String] = []
        if let author = preset.author, !author.isEmpty { parts.append(author) }
        if let license = preset.license, !license.isEmpty { parts.append(license) }
        if let notes = preset.notes, !notes.isEmpty { parts.append(notes) }
        return parts.isEmpty ? "洛雪脚本音源" : parts.joined(separator: " · ")
    }

    private func add(_ preset: BundledSources.Preset) {
        guard let source = BundledSources.makeSource(preset) else {
            importMessage = "内置音源 \(preset.displayName) 读取失败，包可能不完整"
            return
        }
        store.upsert(source)
        importMessage = "成功添加内置音源：\(preset.displayName)，到下面打开它的开关"
    }

    /// 剪贴板导入：文件选择器出问题时的兜底路径。
    @MainActor
    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importMessage = "剪贴板是空的，先复制音源内容再试"
            return
        }
        let parsed = SourceStore.parseImport(text)
        if !parsed.isEmpty {
            for source in parsed { store.upsertReplacingByName(source) }
            importMessage = "成功导入 \(parsed.count) 条：\(parsed.map(\.name).joined(separator: "、"))"
            return
        }
        var name = "剪贴板脚本音源"
        if text.hasPrefix("/*!"), let firstLine = text.components(separatedBy: .newlines).first,
           let parsed = SourceImportView.scriptName(from: firstLine), !parsed.isEmpty {
            name = parsed
        }
        store.upsertReplacingByName(ThirdPartySource(name: name, kind: .script, script: text))
        importMessage = "成功导入脚本音源：\(name)"
    }

    /// App 自己的 Documents/Imports 目录。用 iTunes/Finder/SSH 把文件放进去就行，
    /// 不经过系统选择器，绕开它可能不回调的老问题。
    @MainActor
    private func importFromAppDirectory() {
        let dir = SourceStore.importDirectory()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["js", "mjs", "cjs", "txt", "json", "conf", "json5", "ini"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            Log.warn("音源导入", "App 目录 \(dir.path) 里没有可导入的文件")
            importMessage = "App 目录里还没有音源文件。把 .js 放进 \(dir.path) 再试一次。"
            return
        }
        Log.info("音源导入", "从 App 目录 \(dir.path) 找到 \(files.count) 个候选文件")
        Task { await importFromFiles(files) }
    }

    /// 解码文本。BOM 和 UTF-16 都要照顾到：洛雪的 .js 常带 UTF-8 BOM，
    /// 直接当 UTF-8 读会在最前面留下不可见字符，导致脚本第一行解析失败。
    private static func decodeText(_ data: Data) -> String? {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.count >= 2 {
            let isUTF16LE = data[0] == 0xFF && data[1] == 0xFE
            let isUTF16BE = data[0] == 0xFE && data[1] == 0xFF
            if isUTF16LE || isUTF16BE {
                let encoding = isUTF16LE
                    ? String.Encoding.utf16LittleEndian
                    : String.Encoding.utf16BigEndian
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
    }

    private static var importableTypes: [UTType] {
        // 洛雪音源是 .js，配置是 .json / .txt；用 item 兜底，避免任何文件在选择器里被置灰
        var types: [UTType] = [.item, .json, .plainText, .data]
        for ext in ["txt", "conf", "js", "json5", "ini"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// 从文件导入：先按 JSON 配置解析，认不出来就当 JS 脚本音源存。
    ///
    /// 整个函数标 @MainActor：普通 async 方法跨 await 后会在通用执行器上写 @State，
    /// 表现就是「选完没反应」。
    @MainActor
    private func importFromFiles(_ urls: [URL]) async {
        isImportingFiles = true
        defer { isImportingFiles = false }
        Log.info("音源导入", "开始导入 \(urls.count) 个文件：\(urls.map(\.lastPathComponent).joined(separator: ", "))")

        var added = 0
        var addedNames: [String] = []
        var failures: [String] = []

        for url in urls {
            Log.info("音源导入", "处理 \(url.lastPathComponent)，路径 \(url.path)")
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                Log.error("音源导入", "\(url.lastPathComponent) 读取失败（无权限或文件已移动）")
                failures.append("\(url.lastPathComponent)（读不到，可能没给文件访问权限）")
                continue
            }
            Log.debug("音源导入", "\(url.lastPathComponent) 读到 \(data.count) 字节")
            // 洛雪的 .js 常带 UTF-8 BOM，直接当 UTF-8 读会在最前面留不可见字符，
            // 脚本第一行就解析失败；UTF-16 也要能读。
            guard let text = Self.decodeText(data) else {
                Log.error("音源导入", "\(url.lastPathComponent) 用 UTF-8/UTF-16/GBK 都解不出文本，可能是二进制或加密文件")
                failures.append("\(url.lastPathComponent)（无法解码，可能不是明文脚本）")
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.error("音源导入", "\(url.lastPathComponent) 是空文件")
                failures.append("\(url.lastPathComponent)（空文件或非文本）")
                continue
            }
            Log.debug("音源导入", "\(url.lastPathComponent) 解码成功，\(text.count) 字符，开头: \(trimmed.prefix(80))")

            let parsed = SourceStore.parseImport(text)
            if !parsed.isEmpty {
                Log.info("音源导入", "\(url.lastPathComponent) 按 JSON 配置解析出 \(parsed.count) 条：\(parsed.map(\.name).joined(separator: ", "))")
                for source in parsed { store.upsertReplacingByName(source) }
                added += parsed.count
                addedNames.append(contentsOf: parsed.map(\.name))
                continue
            }
            Log.info("音源导入", "\(url.lastPathComponent) 不是 JSON 配置，转按脚本判断")

            // 混淆过的脚本里 lx.on 这些字面量是编码的，只能靠扩展名和整体特征判断
            let isScriptFile = ["js", "mjs", "cjs", "txt"].contains(url.pathExtension.lowercased())
            let looksLikeScript = text.contains("globalThis")
                || text.contains("module.exports")
                || text.contains("require(")
                || text.contains("=>")
                || text.contains("function")
            if isScriptFile || looksLikeScript {
                let name = url.deletingPathExtension().lastPathComponent
                let finalName = name.isEmpty ? "导入的脚本音源" : name
                store.upsertReplacingByName(ThirdPartySource(name: finalName, kind: .script, script: text))
                Log.info("音源导入", "\(url.lastPathComponent) 判定为脚本音源（扩展名命中=\(isScriptFile)），已存为「\(finalName)」，\(text.count) 字符")
                added += 1
                addedNames.append(finalName)
            } else {
                Log.error("音源导入", "\(url.lastPathComponent) 既不是配置也看不出是脚本（扩展名 \(url.pathExtension.lowercased())）")
                failures.append("\(url.lastPathComponent)（不是音源配置，也看不出是脚本）")
            }
        }

        if failures.isEmpty {
            importMessage = added > 0
                ? "成功导入 \(added) 条：\(addedNames.joined(separator: "、"))"
                : "文件里没解析出音源"
        } else {
            importMessage = added > 0
                ? "导入 \(added) 条（\(addedNames.joined(separator: "、"))）；失败 \(failures.count) 个：\(failures.joined(separator: "、"))"
                : "全部失败：\(failures.joined(separator: "、"))"
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
                    Text("特殊键：apiKey（密钥，多个用逗号分隔）、apiKeys、source（限定平台，酷狗填 kg）、quality。")
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
        // 用酷狗一首大众都听过的歌做探针
        let song = Song(title: "晴天",
                        artist: "周杰伦",
                        album: "叶惠美",
                        duration: 269,
                        source: .kugou,
                        kugouHash: "B3A52A7A958BF0AED0EBFBA2E9A818B7",
                        kugouAudioID: "20505418",
                        kugouAlbumID: "966846")

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
                Text("支持洛雪（lx-music）音源脚本。粘进来先按 JSON 配置试，认不出来就整段当 JS 脚本存。")
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
            .navigationTitle("粘贴导入")
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "内容是空的"
            return
        }
        let parsed = SourceStore.parseImport(trimmed)
        if !parsed.isEmpty {
            for source in parsed { store.upsertReplacingByName(source) }
            dismiss()
            return
        }
        // 整段当 JS 脚本，名字从 /*! @name xxx */ 里取
        var name = "粘贴的脚本音源"
        if trimmed.hasPrefix("/*!"), let firstLine = trimmed.components(separatedBy: .newlines).first,
           let parsedName = Self.scriptName(from: firstLine), !parsedName.isEmpty {
            name = parsedName
        }
        store.upsert(ThirdPartySource(name: name, kind: .script, script: trimmed))
        dismiss()
    }

    /// 从 `/*! @name 音源名 */` 里取音源名。
    static func scriptName(from headerLine: String) -> String? {
        for key in ["@name", "@名称"] {
            guard let range = headerLine.range(of: key) else { continue }
            let rest = headerLine[range.upperBound...]
            let end = rest.firstIndex(where: { $0 == "*" || $0 == "\n" }) ?? rest.endIndex
            let value = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
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
