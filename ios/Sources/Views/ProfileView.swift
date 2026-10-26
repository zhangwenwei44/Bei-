import SwiftUI

/// 我的：音源、播放偏好、版本与授权。
struct ProfileView: View {
    @EnvironmentObject private var store: PlayerStore
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var kugouAuth = KugouAuth.shared
    // 🔴 v2.9.0：一机一码授权状态
    @ObservedObject private var license = LicenseManager.shared
    /// 订阅迷你播放条可见性，只为在播放时给设置列表底部留出安全间距（见下方 List 的 bottom padding）。
    @ObservedObject private var mini = PlayerStore.shared.mini
    @StateObject private var updater = AppUpdater.shared
    /// 自动预缓存下一首 —— 用户手动开关，优先级高于网络判断（默认开启）。
    @AppStorage("aurora.autoPrecache") private var autoPrecacheEnabled: Bool = true
    /// 🔴 v2.6.2：歌词页歌手写真背景开关（歌词页背景默认用当前歌手的写真）
    @AppStorage("aurora.lyricsArtistPhoto") private var lyricsArtistPhoto: Bool = true
    // 🔴 v2.5.39：播放器主题精简为唯一的「经典封面」，主题选择器已移除（保留旧键不影响）。
    private var autoPrecacheBinding: Binding<Bool> {
        Binding(get: { autoPrecacheEnabled },
                set: { autoPrecacheEnabled = $0 })
    }
    /// 「检查更新」和「关于」点了完全没反应，只有排在最后的更新日志能弹出来。
    private enum Sheet: String, Identifiable {
        case about, update, changelog, kugouImport, kugouLogin, licenseMaker
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    /// QQ 交流群弹层（v2.5.41：启动公告取消后，入口改为设置页这一行）
    @State private var showQQGroup = false
    /// 酷狗分享链接 / specialid 输入框。
    @State private var kugouCodeInput = ""
    @State private var kugouImporting = false
    @State private var kugouImportError: String? = nil
    @State private var recommendedLoading = false
    @State private var recommendedPlaylists: [Playlist] = []

    var body: some View {
        List {
            // MARK: 酷狗音乐（扫码登录）—— 顶部大卡片
            Section {
                if kugouAuth.isLoggedIn {
                    HStack(spacing: 12) {
                        CoverImage(url: kugouAuth.avatarURL,
                                   fallbackKeys: ["kg-user:\(kugouAuth.userId)"],
                                   seed: kugouAuth.nickname,
                                   size: 48, corner: 10)  // 🔴 v2.8.4 头像改方形
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kugouAuth.nickname.isEmpty ? "酷狗用户 \(kugouAuth.userId)" : kugouAuth.nickname)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppStyle.primaryText)
                            HStack(spacing: 6) {
                                Text("已连接酷狗")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                if kugouAuth.isVip {
                                    Text("VIP")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.yellow, in: Capsule())
                                }
                            }
                        }
                        Spacer()
                        Button { kugouAuth.logout() } label: {
                            Text("断开").font(.system(size: 13))
                        }
                    }
                } else {
                    Button {
                        NotificationCenter.default.post(name: .auroraShowKugouLogin, object: nil)
                    } label: {
                        HStack {
                            // 酷狗品牌登录图标（绿实心圆 + 白色斜话筒）
                            KugouLogoIcon(size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("酷狗音乐")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AppStyle.primaryText)
                                Text("扫码登录，同步云端歌单")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppStyle.tertiaryText)
                            }
                            Spacer()
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 20))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                headerText("酷狗音乐")
            } footer: {
                Text("登录后可同步酷狗云端歌单，把 Aurora 里的歌曲保存到酷狗账号。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Section {
                NavigationLink {
                    SourceSettingsView()
                } label: {
                    HStack {
                        Label("第三方音源", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(sourceSummary)
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
            } header: {
                headerText("音源")
            } footer: {
                Text("官方接口优先；解析不到时按顺序逐个尝试已启用的音源，第一个返回可用地址的胜出。音源只保存在本机。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Section {
                Picker(selection: Binding(
                    get: { ThemeSettings.mode },
                    set: { ThemeSettings.mode = $0 }
                )) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Label("外观", systemImage: "circle.lefthalf.filled")
                }
            } header: {
                headerText("外观")
            } footer: {
                Text("浅色为蓝白配色，深色适合夜间使用。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Section {
                // 🔴 v2.7.4：改成一整页（酷狗风格的音质页），
                // 原来的系统 Picker 只有一行、看不到各档位差别。
                NavigationLink {
                    QualitySettingsView()
                } label: {
                    HStack {
                        Label("播放音质", systemImage: "waveform")
                        Spacer()
                        Text(sourceStore.quality.title)
                            .foregroundStyle(AppStyle.tertiaryText)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }

                HStack {
                    Label("睡眠定时", systemImage: "moon.zzz")
                    Spacer()
                    Menu {
                        Button("关闭") { store.setSleepTimer(minutes: 0) }
                        ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                            Button("\(minutes) 分钟") { store.setSleepTimer(minutes: minutes) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sleepText)
                                .foregroundStyle(AppStyle.tertiaryText)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                }

                HStack {
                    Label("歌词翻译", systemImage: "character.bubble")
                    Spacer()
                    Toggle("", isOn: Binding(get: { store.showTranslation },
                                              set: { store.showTranslation = $0 }))
                        .labelsHidden()
                        .tint(AppStyle.accent)
                }

                HStack {
                    Label("高刷新率", systemImage: "speedometer")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { HighRefreshController.shared.isEnabled },
                        set: { HighRefreshController.shared.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .tint(AppStyle.accent)
                }

                // 自动预缓存开关（优先级高于 WiFi/蜂窝网络判断）
                Toggle(isOn: autoPrecacheBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动预缓存下一首")
                            Text("仅 WiFi 时生效，蜂窝/低数据模式自动关闭")
                                .font(.system(size: 11))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .tint(AppStyle.accent)
                }
                // 🔴 v2.6.2：歌词页歌手写真背景
                Toggle(isOn: $lyricsArtistPhoto) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("歌词页歌手写真背景")
                            Text("取不到歌手写真时自动回退为封面取色背景")
                                .font(.system(size: 11))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    } icon: {
                        Image(systemName: "person.crop.rectangle.fill")
                    }
                    .tint(AppStyle.accent)
                }
            } header: {
                headerText("播放")
            }

            Section {
                Button {
                    sheet = .kugouImport
                } label: {
                    Label("导入酷狗歌单", systemImage: "square.and.arrow.down.on.square")
                }
                // 🔴 用 Button 触发手动写备份 → 再调系统分享面板
                // 旧写法 ShareLink(item: backupTempURL()) 会在每次 body 渲染时写一个新备份到 tmp
                // 每秒 5~10 次 → 磁盘爆满 + CPU 打满 + 卡顿
                Button {
                    if let url = try? writeBackupOnce() {
                        showShareSheet(url: url)
                    }
                } label: {
                    Label("导出歌单备份", systemImage: "square.and.arrow.up")
                }
                Button {
                    // 用 FilePicker 而非 SwiftUI .fileImporter：
                    // 1. .fileImporter 在 iOS 16 上和 .sheet 共用呈现通道，回调被静默吞掉
                    // 2. allowedContentTypes: [.json] 太严格，某些 .json 文件的 UTI 被标记为 .data
                    // FilePicker 绕开 SwiftUI 呈现体系，直接 present UIDocumentPickerViewController
                    FilePicker.pick(types: [.json, .data, .item], multiple: false) { urls in
                        if let url = urls.first {
                            Task { await importBackup(from: url) }
                        }
                    }
                } label: {
                    Label("恢复歌单备份", systemImage: "arrow.uturn.backward.circle")
                }
            } header: {
                headerText("我的音乐")
            }

            Section {
                Button {
                    sheet = .update
                } label: {
                    HStack {
                        Label("检查更新", systemImage: "arrow.down.circle")
                        Spacer()
                        if updater.phase.isBusy {
                            ProgressView()
                        } else {
                            Text(updateBadge)
                                .font(.system(size: 13))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                }
                .disabled(updater.phase.isBusy)
                Button {
                    sheet = .changelog
                } label: {
                    HStack {
                        Label("更新日志", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
            } header: {
                // 🔴 v2.9.1：连点 7 次「版本」进授权码生成器（隐藏入口，进去了还有口令）
                headerText("版本")
                    .onTapGesture(count: 7) { sheet = .licenseMaker }
            }

            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    HStack {
                        Label("运行日志", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        Text("\(LogStore.shared.entries.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .foregroundStyle(AppStyle.primaryText)
                }

                // 🔴 v2.9.0：授权状态 —— 点一下复制设备码（换授权码时要用）
                Button {
                    UIPasteboard.general.string = license.deviceID
                    Haptics.light()
                } label: {
                    HStack {
                        Label("授权状态", systemImage: "lock.shield")
                        Spacer()
                        Text(license.isActivated ? "已激活" : "未激活")
                            .font(.system(size: 12))
                            .foregroundStyle(license.isActivated ? AppStyle.accent : Color.red)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .foregroundStyle(AppStyle.primaryText)
                }

                Button {
                    sheet = .about
                } label: {
                    HStack {
                        Label("关于 Aurora Music", systemImage: "info.circle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .foregroundStyle(AppStyle.primaryText)
                }

                // 🔴 v2.5.41：QQ 群入口从「启动公告弹窗」挪到设置页（启动时不再弹任何公告）
                Button {
                    showQQGroup = true
                } label: {
                    HStack {
                        Label("加入 QQ 交流群", systemImage: "person.3.fill")
                        Spacer()
                        Text(QQAnnouncementView.groupNumber)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppStyle.tertiaryText)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .foregroundStyle(AppStyle.primaryText)
                }
            }
        }
        .sheet(isPresented: $showQQGroup) {
            QQAnnouncementView()
        }
        .listStyle(.insetGrouped)
        .compatScrollContentBackground(.hidden)
        .background(AppStyle.background)
        // 🔴 播放时迷你播放条占据底部安全区，给列表末尾（"关于 Aurora Music" 等）留出安全间距，
        // 避免被播放条挡住。未播放时 mini 不显示，padding 为 0，不留多余空白。
        .padding(.bottom, mini.isVisible ? 60 : 0)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        // 🔴 底部留白已由 RootView 的 .safeAreaInset(edge:.bottom) 统一处理
        // （播放条现在是 TabView 的 inset 内容，不是浮层盖在列表上）。
        // 这里再手动 inset 会造成双重留白。
        .sheet(item: $sheet) { item in
            switch item {
            case .about: AboutView()
            case .update: UpdateView()
            case .changelog: ChangelogView()
            case .kugouImport:
                if #available(iOS 16.0, *) {
                    kugouImportSheet.presentationDetents([.medium, .large])
                } else {
                    kugouImportSheet
                }
            case .kugouLogin: KugouLoginSheet()
            case .licenseMaker: LicenseGeneratorView()
            }
        }
        .task {
            if case .idle = updater.phase {
                await updater.check()
            }
        }
    }

    private var updateBadge: String {
        switch updater.phase {
        case .upToDate:
            return "已是最新 \(AppUpdater.shared.versionText)"
        case .available(let release):
            return release.tag_name
        case .failed:
            return "检查失败"
        default:
            return AppUpdater.shared.versionText
        }
    }

    private var sourceSummary: String {
        let total = sourceStore.sources.count
        let enabled = sourceStore.enabledSources.count
        if total == 0 { return "未配置" }
        return "\(enabled)/\(total) 启用"
    }

    private var sleepText: String {
        guard let remaining = store.sleepTimerRemaining, remaining > 0 else { return "关闭" }
        return "\(Int(ceil(remaining / 60))) 分钟后"
    }

    private var kugouImportSheet: some View {
        CompatNavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // 精选歌单快捷入口
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("🔥 精选歌单（点一下直接导入）")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if recommendedLoading { ProgressView().controlSize(.small) }
                    }

                    if recommendedPlaylists.isEmpty, !recommendedLoading {
                        Button("加载精选歌单") {
                            Task { await loadRecommended() }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(recommendedPlaylists.prefix(15)) { pl in
                                    Button {
                                        Task { await importRecommended(pl) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            AsyncImage(url: pl.coverURL) { phase in
                                                switch phase {
                                                case .success(let img):
                                                    img.resizable().scaledToFill()
                                                default:
                                                    Color.gray.opacity(0.3)
                                                }
                                            }
                                            .frame(width: 100, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))

                                            Text(pl.name)
                                                .font(.system(size: 12))
                                                .foregroundStyle(AppStyle.primaryText)
                                                .lineLimit(2)
                                                .frame(width: 100, alignment: .leading)

                                            Text("\(pl.trackCount) 首")
                                                .font(.system(size: 10))
                                                .foregroundStyle(AppStyle.tertiaryText)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(kugouImporting)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 16)

                Divider()

                // 手动输入区
                VStack(alignment: .leading, spacing: 12) {
                    Text("手动粘贴歌单链接")
                        .font(.system(size: 14, weight: .semibold))

                    Text("从酷狗 App 点歌单 → 右上角分享 → 复制链接，粘贴到这里")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)

                    TextField("https://t.kugou.com/xxx 或 12345", text: $kugouCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)

                    HStack(spacing: 12) {
                        Button("取消") {
                            sheet = nil; kugouCodeInput = ""; kugouImportError = nil
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await doKugouImport() }
                        } label: {
                            HStack {
                                if kugouImporting { ProgressView().controlSize(.small) }
                                Text(kugouImporting ? "导入中..." : "导入")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(kugouImporting || kugouCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let err = kugouImportError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                            if err.contains("失效") || err.contains("没有歌曲") {
                                Text("💡 试试上方精选歌单，或从酷狗 App 重新分享一个有效歌单")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.tertiaryText)
                            }
                        }
                    }

                    if kugouImporting {
                        ProgressView("正在解析并下载歌曲列表...")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
                .padding()

                Spacer()
            }
            .navigationTitle("导入酷狗歌单")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if recommendedPlaylists.isEmpty {
                    await loadRecommended()
                }
            }
        }
    }

    private func loadRecommended() async {
        recommendedLoading = true
        defer { recommendedLoading = false }
        let (pls, _) = await KugouClient.shared.recommendedPlaylists(page: 1)
        recommendedPlaylists = pls
    }

    private func importRecommended(_ playlist: Playlist) async {
        kugouImporting = true; kugouImportError = nil
        defer { kugouImporting = false }
        guard let specialID = playlist.id.split(separator: ":").last else {
            kugouImportError = "无法识别歌单 ID"; return
        }
        do {
            let songs = try await KugouClient.shared.specialSongs(specialID: String(specialID))
            guard !songs.isEmpty else {
                kugouImportError = "歌单加载失败，可能已失效"
                return
            }
            library.importPlaylist(name: playlist.name, songs: songs)
            Haptics.soft()
            kugouCodeInput = ""
            sheet = nil
        } catch {
            kugouImportError = "导入失败：\(error.localizedDescription)"
        }
    }

    private func doKugouImport() async {
        kugouImporting = true; kugouImportError = nil
        defer { kugouImporting = false }
        do {
            let (playlist, songs) = try await KugouClient.shared.fetchPlaylistByCode(kugouCodeInput)
            guard !songs.isEmpty else {
                kugouImportError = "歌单里没有歌曲 — 可能已过期或被删除"
                return
            }
            library.importPlaylist(name: playlist.name, songs: songs)
            Haptics.soft()
            kugouCodeInput = ""
            sheet = nil
        } catch {
            let msg = error.localizedDescription
            if msg.contains("URL") || msg.contains("URLSession") || msg.contains("find") {
                kugouImportError = "链接解析失败 — 试试从酷狗 App 重新分享一个有效的歌单链接"
            } else {
                kugouImportError = "导入失败：\(msg)"
            }
        }
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AppStyle.tertiaryText)
    }

    /// 备份 JSON 写到临时目录，返回 URL 供 ShareLink 使用
    /// 只在用户点"导出"时写一次备份文件（不再在 body 渲染时疯狂写）
    private func writeBackupOnce() throws -> URL {
        let fm = FileManager.default
        let docDir = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let url = docDir.appendingPathComponent("aurora-backup-latest.json")
        let data = try library.backupAllData()
        try data.write(to: url, options: .atomic)
        Log.info("备份", "一次性写出备份 \(url.path) (\(data.count) bytes)")
        return url
    }

    private func showShareSheet(url: URL) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first(where: { $0.isKeyWindow }) else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = window
        vc.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
        window.rootViewController?.present(vc, animated: true)
    }

    /// 从备份文件恢复
    private func importBackup(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try library.restoreFromBackup(data: data, merge: true)
            Haptics.soft()
            showToast = "备份恢复成功"
        } catch {
            Log.warn("备份", "恢复失败 \(error.localizedDescription)")
            showToast = "恢复失败：\(error.localizedDescription)"
        }
    }

    @State private var showToast: String?
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Aurora Music")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Text("一个用于学习的第三方音乐播放器。界面与播放交互参考酷狗音乐，仅供个人学习与技术研究使用。")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.secondaryText)

                    // 🔴 v2.9.4：原「第三方音源怎么用」「第三方音源署名」整块移除，
                    // 换成免责声明 —— 关于页只交代产品定位与使用责任，不再涉及音源来源细节。
                    VStack(alignment: .leading, spacing: 10) {
                        Text("免责声明")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppStyle.primaryText)
                        ForEach(disclaimerItems.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(AppStyle.tertiaryText.opacity(0.5))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(disclaimerItems[index])
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.secondaryText)
                            }
                        }
                    }

                    Text("继续使用即表示你已阅读并同意上述条款。本项目仅供个人学习与研究使用，请遵守各平台服务条款，不要用于商业分发。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .padding(20)
            }
            .background(AppStyle.background)
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private let disclaimerItems = [
        "本应用仅用于个人学习与技术交流，不提供任何音乐资源的存储、上传或分发服务。",
        "歌曲播放地址由用户自行配置，本应用不保证其可用性、合法性与稳定性。",
        "所有音乐内容的版权归各自权利人所有，如有侵权请联系相关权利人，本应用不承担责任。",
        "本应用与酷狗音乐官方无关，界面与交互仅为学习参考，不用于任何商业用途。",
        "用户应对自己的使用行为承担全部责任，请在遵守当地法律法规的前提下使用。",
    ]
}
