import SwiftUI

/// 我的：音源、播放偏好、版本与授权。
struct ProfileView: View {
    @EnvironmentObject private var store: PlayerStore
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var kugouAuth = KugouAuth.shared
    // 🔴 v2.9.8：Aurora 云账号（Supabase 邮件注册/登录 + 收藏歌单同步）
    @ObservedObject private var cloud = CloudAccount.shared
    // 🔴 v2.9.0：一机一码授权状态
    @ObservedObject private var license = LicenseManager.shared
    /// 订阅迷你播放条可见性，只为在播放时给设置列表底部留出安全间距（见下方 List 的 bottom padding）。
    @ObservedObject private var mini = PlayerStore.shared.mini
    @StateObject private var updater = AppUpdater.shared
    /// 自动预缓存下一首 —— 用户手动开关，优先级高于网络判断（默认开启）。
    @AppStorage("aurora.autoPrecache") private var autoPrecacheEnabled: Bool = true
    /// 🔴 v2.6.2：歌词页歌手写真背景开关（歌词页背景默认用当前歌手的写真）
    @AppStorage("aurora.lyricsArtistPhoto") private var lyricsArtistPhoto: Bool = true
    /// 🔴 v2.9.11：下载歌曲（我的音乐）是否按字母（拼音首字母）排序；开启=分组+右侧 A–Z 索引，关闭=按下载顺序平铺。
    @AppStorage("aurora.downloadAlphabeticalSort") private var downloadAlphabeticalSort: Bool = true
    // 🔴 v2.5.39：播放器主题精简为唯一的「经典封面」，主题选择器已移除（保留旧键不影响）。
    private var autoPrecacheBinding: Binding<Bool> {
        Binding(get: { autoPrecacheEnabled },
                set: { autoPrecacheEnabled = $0 })
    }
    /// 「检查更新」和「关于」点了完全没反应，只有排在最后的更新日志能弹出来。
    private enum Sheet: String, Identifiable {
        case about, update, changelog, kugouLogin, licenseMaker, unlock, banner
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    /// 🔴 2026-11-08：运行日志改成隐藏入口（长按「版本」标题 1.5 秒进入），
    /// 列表里不再显示这一行；用隐藏 NavigationLink 保持原来的 push 行为。
    @State private var diagnosticsActive = false
    /// QQ 交流群弹层（v2.5.41：启动公告取消后，入口改为设置页这一行）
    @State private var showQQGroup = false
    // 🔴 v2.9.8：云账号输入框
    @State private var cloudEmail = ""
    @State private var cloudPassword = ""
    @State private var cloudError: String? = nil
    // 🔴 v2.9.8：未登录时云账号默认折叠（只留一行入口，点开才显示登录框）
    @State private var cloudExpanded = false
    @State private var cloudSignedInExpanded = false  // 🔴 登录后云账号区默认折叠，点开才展开

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
                            LucideIcon(icon: .qrCode, size: 20, color: AppStyle.tertiaryText)
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

            // MARK: Aurora 云账号（Supabase）—— 邮箱登录 + 收藏歌单同步
            Section {
                if cloud.isSignedIn {
                    // 🔴 用户要求：登录后云账号区改为可折叠（DisclosureGroup）。
                    DisclosureGroup(isExpanded: $cloudSignedInExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let email = cloud.userEmail {
                                Text(email)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.secondaryText)
                            }
                            // 🔴 用户要求：云账号不显示歌曲同步信息（同步中/已同步/同步失败等状态文字），保留邮箱与同步按钮。
                            HStack(spacing: 12) {
                                Button {
                                    sheet = .unlock
                                } label: {
                                    Text("解锁码")
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(AppStyle.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(AppStyle.accent)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    sheet = .banner
                                } label: {
                                    Text("横屏广告更换")
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(AppStyle.primaryText)
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                Task {
                                    do { try await cloud.signOut() }
                                    catch { cloudError = CloudAccount.localizedCloudError(error) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 14, weight: .medium))
                                    Text("退出登录")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            LucideIcon(icon: .cloud, size: 18, color: AppStyle.primaryText)
                            Text("Aurora 云账号")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppStyle.primaryText)
                            Spacer()
                            if cloud.isBusy {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        // 🔴 v2.9.8：未登录时默认折叠 —— 只留一行入口，
                        // 点一下才展开邮箱/密码输入框，设置页不再被登录框占满。
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                cloudExpanded.toggle()
                            }
                            cloudError = nil
                        } label: {
                            HStack(spacing: 10) {
                                LucideIcon(icon: .cloud, size: 18, color: AppStyle.accent)
                                Text("登录云账号")
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppStyle.primaryText)
                                Spacer()
                                if cloud.isBusy {
                                    ProgressView().controlSize(.small)
                                }
                                Text("未登录")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                LucideIcon(icon: .chevronRight, size: 12, color: AppStyle.tertiaryText)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppStyle.tertiaryText)
                                    .rotationEffect(.degrees(cloudExpanded ? 90 : 0))
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if cloudExpanded {
                            TextField("邮箱", text: $cloudEmail)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            SecureField("密码", text: $cloudPassword)
                                .textContentType(.password)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            if let err = cloudError {
                                Text(err)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                            }
                            HStack(spacing: 12) {
                                Button {
                                    cloudError = nil
                                    Task {
                                        do {
                                            try await cloud.signIn(email: cloudEmail, password: cloudPassword)
                                        } catch { cloudError = CloudAccount.localizedCloudError(error) }
                                    }
                                } label: {
                                    Text("登录")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } header: {
                headerText("Aurora 云账号")
            }             footer: {
                Text("登录 Aurora 云账号后，收藏和自建歌单会保存到云端、跨设备恢复。与酷狗账号相互独立。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Section {
                NavigationLink {
                    SourceSettingsView()
                } label: {
                    HStack {
                        Label {
                            Text("第三方音源")
                        } icon: {
                            LucideIcon(icon: .radioTower, size: 18, color: AppStyle.secondaryText)
                        }
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
                    Label {
                        Text("外观")
                    } icon: {
                        LucideIcon(icon: .sunMoon, size: 18, color: AppStyle.secondaryText)
                    }
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
                        Label {
                            Text("播放音质")
                        } icon: {
                            LucideIcon(icon: .audioWaveform, size: 18, color: AppStyle.secondaryText)
                        }
                        Spacer()
                        Text(sourceStore.quality.title)
                            .foregroundStyle(AppStyle.tertiaryText)
                        LucideIcon(icon: .chevronRight, size: 12, color: AppStyle.tertiaryText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }

                HStack {
                    Label {
                        Text("睡眠定时")
                    } icon: {
                        LucideIcon(icon: .alarmClock, size: 18, color: AppStyle.secondaryText)
                    }
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
                            LucideIcon(icon: .chevronsUpDown, size: 10, color: AppStyle.tertiaryText)
                                .font(.system(size: 10))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    }
                }

                HStack {
                    Label {
                        Text("高刷新率")
                    } icon: {
                        LucideIcon(icon: .gauge, size: 18, color: AppStyle.secondaryText)
                    }
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
                        LucideIcon(icon: .refreshCw, size: 18, color: AppStyle.secondaryText)
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
                        LucideIcon(icon: .squareUser, size: 18, color: AppStyle.secondaryText)
                    }
                    .tint(AppStyle.accent)
                }
                // 🔴 2026-11-08：图标换成用户给的「↑ A/Z」；同一个开关在
                //    「我的音乐 → 下载歌曲」板块顶部也能直接设置。
                Toggle(isOn: $downloadAlphabeticalSort) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("下载歌曲按字母排序")
                            Text("开启后按歌名拼音首字母分组并显示右侧 A–Z 索引；关闭则按下载顺序平铺。我的音乐页也可设置")
                                .font(.system(size: 11))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                    } icon: {
                        LucideIcon(icon: .arrowUpAZ, size: 18, color: AppStyle.secondaryText)
                    }
                    .tint(AppStyle.accent)
                }
            } header: {
                headerText("播放")
            }

            Section {
                Button {
                    sheet = .update
                } label: {
                    HStack {
                        Label {
                            Text("检查更新")
                        } icon: {
                            LucideIcon(icon: .download, size: 18, color: AppStyle.secondaryText)
                        }
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
                        Label {
                            Text("更新日志")
                        } icon: {
                            LucideIcon(icon: .fileClock, size: 18, color: AppStyle.secondaryText)
                        }
                        Spacer()
                        LucideIcon(icon: .chevronRight, size: 12, color: AppStyle.tertiaryText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                }
            } header: {
                // 🔴 2026-11-08：隐藏入口全部收在「版本」标题上 ——
                //    连点 7 次 → 授权码生成器；长按 1.5 秒 → 运行日志（列表里已不再显示）。
                headerText("版本")
                    .onTapGesture(count: 7) { sheet = .licenseMaker }
                    .onLongPressGesture(minimumDuration: 1.5) { diagnosticsActive = true }
            }

            Section {
                // 🔴 v2.9.0：授权状态 —— 点一下复制设备码（换授权码时要用）
                Button {
                    UIPasteboard.general.string = license.deviceID
                    Haptics.light()
                } label: {
                    HStack {
                        Label {
                            Text("授权状态")
                        } icon: {
                            LucideIcon(icon: .shield, size: 18, color: AppStyle.secondaryText)
                        }
                        Spacer()
                        Text(license.isActivated ? "已激活" : "未激活")
                            .font(.system(size: 12))
                            .foregroundStyle(license.isActivated ? AppStyle.accent : Color.red)
                        LucideIcon(icon: .copy, size: 12, color: AppStyle.tertiaryText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .foregroundStyle(AppStyle.primaryText)
                }

                Button {
                    sheet = .about
                } label: {
                    HStack {
                        Label {
                            Text("关于 Aurora Music")
                        } icon: {
                            LucideIcon(icon: .info, size: 18, color: AppStyle.secondaryText)
                        }
                        Spacer()
                        LucideIcon(icon: .chevronRight, size: 12, color: AppStyle.tertiaryText)
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
                        Label {
                            Text("加入 QQ 交流群")
                        } icon: {
                            LucideIcon(icon: .users, size: 18, color: AppStyle.secondaryText)
                        }
                        Spacer()
                        Text(QQAnnouncementView.groupNumber)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppStyle.tertiaryText)
                        LucideIcon(icon: .chevronRight, size: 12, color: AppStyle.tertiaryText)
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
        // 🔴 v2.9.6(修正)：顶部淡蓝渐变钉在列表顶部，上滑不消失（与主页一致）。
        .kugouPinnedTopFade(height: 280)
        // 🔴 播放时迷你播放条占据底部安全区，给列表末尾（"关于 Aurora Music" 等）留出安全间距，
        // 避免被播放条挡住。未播放时 mini 不显示，padding 为 0，不留多余空白。
        .padding(.bottom, mini.isVisible ? 60 : 0)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        // 🔴 v2.9.6：大标题导航栏刷成淡蓝，和列表顶部的渐变带连成一片
        // （不刷的话大标题区是白的，下面列表顶部却是淡蓝，中间会有一条硬边）。
        .kugouNavigationBarTint()
        // 🔴 底部留白已由 RootView 的 .safeAreaInset(edge:.bottom) 统一处理
        // （播放条现在是 TabView 的 inset 内容，不是浮层盖在列表上）。
        // 这里再手动 inset 会造成双重留白。
        .sheet(item: $sheet) { item in
            switch item {
            case .about: AboutView()
            case .update: UpdateView()
            case .changelog: ChangelogView()
            case .kugouLogin: KugouLoginSheet()
            case .licenseMaker: LicenseGeneratorView(requireCloudLogin: false)
            case .unlock: LicenseGeneratorView(requireCloudLogin: false)   // 🔴 解锁码：打开授权码生成器（真实功能）
            case .banner: LabView()                // 🔴 横屏广告更换：打开横幅广告管理（真实功能）
            }
        }
        // 🔴 2026-11-08：运行日志的隐藏 NavigationLink（列表里不显示任何一行），
        //    由「版本」标题长按触发；沿用 DiscoverView 已验证的
        //    .background(NavigationLink(isActive:)) 模式，保持 push 进二级页的行为。
        .background(
            NavigationLink(isActive: $diagnosticsActive) {
                DiagnosticsView()
            } label: { EmptyView() }
        )
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
            // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
            .kugouNavigationBarBackground()
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
