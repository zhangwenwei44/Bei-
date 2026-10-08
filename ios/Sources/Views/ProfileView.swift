import SwiftUI

/// 我的：音源、播放偏好、存储。
struct ProfileView: View {
    @EnvironmentObject private var store: PlayerStore
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var library = LibraryStore.shared
    @StateObject private var updater = AppUpdater.shared
    /// 自动预缓存下一首 —— 用户手动开关，优先级高于网络判断（默认开启）。
    @AppStorage("aurora.autoPrecache") private var autoPrecacheEnabled: Bool = true
    private var autoPrecacheBinding: Binding<Bool> {
        Binding(get: { autoPrecacheEnabled },
                set: { autoPrecacheEnabled = $0 })
    }
    /// 整个页面只挂一个 sheet。
    ///
    /// 之前这里是三个并列的 .sheet(isPresented:)。iOS 16 的 SwiftUI 里同一个
    /// view 挂多个 sheet 只有一个可靠生效，其余静默失败——实际表现就是
    /// 「检查更新」和「关于」点了完全没反应，只有排在最后的更新日志能弹出来。
    private enum Sheet: String, Identifiable {
        case about, update, changelog
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    var body: some View {
        List {
            // MARK: 账号
            Section {
                if let user = auth.currentUser {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(AppStyle.accent.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppStyle.primaryText)
                            Text("已登录")
                                .font(.system(size: 12))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                        Spacer()
                    }
                    Button(role: .destructive) {
                        auth.logout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 44))
                            .foregroundStyle(AppStyle.tertiaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("游客模式")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppStyle.primaryText)
                            Text("登录后可以在多设备间同步歌单")
                                .font(.system(size: 12))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                        Spacer()
                    }
                    // 游客模式下没有直接登录按钮 — 退出登录自动回到 LoginView
                    // 如果想在设置页也能登录，可以加一个 Button { auth.logout() } label: { Text("登录") }
                }
            } header: {
                headerText("账号")
            } footer: {
                Text("登录后收藏、歌单、下载记录会按账号独立保存。当前版本为本地账号，多设备同步即将推出。")
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
                Picker(selection: $sourceStore.quality) {
                    ForEach(MusicQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                } label: {
                    Label("播放音质", systemImage: "waveform")
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
            } header: {
                headerText("播放")
            }

            Section {
                HStack {
                    Label("已下载", systemImage: "internaldrive")
                    Spacer()
                    Text("\(library.downloads.count) 首")
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                Button(role: .destructive) {
                    downloads.clearAll()
                } label: {
                    Label("清空下载", systemImage: "trash")
                }
            } header: {
                headerText("存储")
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
                headerText("版本")
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
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppStyle.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        // 迷你播放条悬浮在 TabBar 上方，会把列表最后几行盖住（运行日志/关于），
        // 有歌在播时给滚动内容让出底部空间
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: store.current == nil ? 0 : 78)
                .accessibilityHidden(true)
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .about: AboutView()
            case .update: UpdateView()
            case .changelog: ChangelogView()
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

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AppStyle.tertiaryText)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Aurora Music")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Text("一个用于学习的第三方音乐播放器。界面与播放交互参考酷狗音乐，音源接口思路来自开源项目 Beans-Music。")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.secondaryText)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("第三方音源怎么用")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppStyle.primaryText)
                        ForEach(steps.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(AppStyle.onAccent)
                                    .frame(width: 18, height: 18)
                                    .background(AppStyle.accent, in: Circle())
                                Text(steps[index])
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.secondaryText)
                            }
                        }
                    }

                    Text("本项目仅供个人学习与研究使用，请遵守各平台服务条款，不要用于商业分发。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("第三方音源署名")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppStyle.primaryText)
                        ForEach(BundledSources.available) { preset in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(preset.displayName) \(preset.version)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppStyle.secondaryText)
                                Text([preset.author, preset.license, preset.homepage]
                                        .compactMap { $0 }
                                        .joined(separator: " · "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.tertiaryText)
                            }
                        }
                        Text("音源脚本由原作者开发并提供服务，本应用只做分发，不保证可用。详见仓库的 THIRD_PARTY_NOTICES.md。")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
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

    private let steps = [
        "在「我的 - 第三方音源」里新增一条音源，接口模板和 JS 脚本两种都行。",
        "接口模板填请求地址；返回播放地址的字段路径填在「地址字段」里，多个用 | 分隔，例如 data.url|url。",
        "如果地址里有 {apiKey}，在「请求头」里加一行 apiKey=xxx，多个用逗号分隔，程序会挨个尝试并记住能用的那个。",
        "保存后打开开关，回到播放页即可。歌曲优先走官方接口，解析不到才会用这里的音源。",
    ]
}
