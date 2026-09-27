import SwiftUI

/// 我的：音源、播放偏好、存储。
struct ProfileView: View {
    @EnvironmentObject private var store: PlayerStore
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var library = LibraryStore.shared
    @StateObject private var updater = AppUpdater.shared
    @State private var isAboutPresented = false
    @State private var isUpdatePresented = false
    @State private var isChangelogPresented = false

    var body: some View {
        List {
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
                Text("官方接口优先；解析不到时按顺序并发尝试已启用的音源，谁先返回可用地址就用谁。音源只保存在本机。")
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
                    isUpdatePresented = true
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
                    isChangelogPresented = true
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
            } footer: {
                Text("检查 GitHub Releases 上的最新版本。越狱设备下载完成后会直接弹出「选取软件安装」。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Section {
                Button {
                    isAboutPresented = true
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
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $isAboutPresented) {
            AboutView()
        }
        .sheet(isPresented: $isUpdatePresented) {
            UpdateView()
        }
        .sheet(isPresented: $isChangelogPresented) {
            ChangelogView()
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
                                    .foregroundStyle(.black)
                                    .frame(width: 18, height: 18)
                                    .background(AppStyle.accent, in: Circle())
                                Text(steps[index])
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppStyle.secondaryText)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("接口模板占位符")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppStyle.primaryText)
                        ForEach(placeholders, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppStyle.secondaryText)
                        }
                    }

                    Text("本项目仅供个人学习与研究使用，请遵守各平台服务条款，不要用于商业分发。")
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

    private let steps = [
        "在「我的 - 第三方音源」里新增一条音源，接口模板和 JS 脚本两种都行。",
        "接口模板填请求地址；返回播放地址的字段路径填在「地址字段」里，多个用 | 分隔，例如 data.url|url。",
        "如果地址里有 {apiKey}，在「请求头」里加一行 apiKey=xxx，多个用逗号分隔，程序会挨个尝试并记住能用的那个。",
        "保存后打开开关，回到播放页即可。歌曲优先走官方接口，解析不到才会用这里的音源。",
    ]

    private let placeholders: [String] = [
        "{id}  歌曲 ID",
        "{name}  歌名（已编码）",
        "{artist}  歌手（已编码）",
        "{keyword}  歌名 + 歌手",
        "{source}  平台代码，酷狗是 kg",
        "{quality}  音质，如 320k / flac",
        "{apiKey}  请求密钥",
    ]
}
