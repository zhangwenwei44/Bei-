import SwiftUI
import UIKit

/// 检查更新弹窗：显示版本、Release note，下载 IPA 并交给越狱安装器安装。
struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var updater = AppUpdater.shared
    @State private var installURL: URL?
    /// 拷到 /var/mobile/Media 的那份。安装器只能读到沙盒外的文件，
    /// 所以分享面板必须用它；沙盒里那份留给「在文件 App 中查看」。
    @State private var sharedURL: URL?
    @State private var shareFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(AppStyle.stroke)
                content
                Spacer(minLength: 0)
            }
            .background(AppStyle.background)
            .navigationTitle("检查更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            // 进入 .ready 就把包搬到公共目录，用户点按钮时直接可用
            .onChange(of: updater.phase) { phase in
                if case let .ready(file) = phase {
                    installURL = file
                    sharedURL = updater.prepareInstall(file)
                    shareFailed = false
                }
            }
        }
    }

    /// 弹出安装器选择。
    ///
    /// 不用 `.sheet` 套 `.sheet`：UpdateView 本身就是 ProfileView 用 sheet 呈现的，
    /// iOS 16 上嵌套 sheet 经常弹不出来。改成直接拿顶层 ViewController present。
    private func presentInstaller() {
        // 优先用公共目录那份；拷不过去就退回沙盒里的
        guard let target = sharedURL ?? installURL else { return }
        shareFailed = !IPAInstaller.presentShareSheet(for: target)
        if shareFailed {
            Log.error("更新", "分享面板没能弹出，请改用「在文件 App 中查看」")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [AppStyle.accent, AppStyle.like],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AppStyle.onAccent)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text("Aurora Music")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Text("当前 \(updater.versionText)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppStyle.secondaryText)
                if let date = updater.lastCheckedAt {
                    Text("上次检查 " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            VStack(spacing: 12) {
                if updater.phase == .checking {
                    ProgressView().tint(AppStyle.accent)
                    Text("正在检查…")
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.secondaryText)
                } else {
                    EmptyStateView(icon: "arrow.triangle.2.circlepath",
                                   title: "还没检查过更新",
                                   message: "点下面的「重新检查」看看有没有新版本")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            actions

        case .upToDate(let current):
            statusBlock(icon: "checkmark.circle.fill",
                        tint: AppStyle.accent,
                        title: "已经是最新版本",
                        message: "当前 \(current)，没有可用更新。")
            actions

        case .available(let release):
            statusBlock(icon: "arrow.down.circle.fill",
                        tint: AppStyle.accent,
                        title: "发现新版本 \(release.tag_name)",
                        message: release.name ?? "")
            if !AppUpdater.notes(from: release.body).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("更新说明")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppStyle.secondaryText)
                    ForEach(Array(AppUpdater.notes(from: release.body).enumerated()), id: \.offset) { _, line in
                        Text("· " + line)
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            installActions(for: release)

        case .downloading(let progress):
            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .tint(AppStyle.accent)
                Text("正在下载安装包 \(Int(progress * 100))%")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(AppStyle.secondaryText)
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            Button("取消下载") { updater.cancel() }
                .font(.system(size: 13))
                .foregroundStyle(AppStyle.tertiaryText)
                .padding(.top, 12)

        case .ready(let fileURL):
            statusBlock(icon: "checkmark.seal.fill",
                        tint: AppStyle.accent,
                        title: "安装包已下载",
                        message: fileURL.lastPathComponent)
            VStack(spacing: 10) {
                // 主路径：系统分享面板里选 AppSync / Zebra / Sileo / Filza
                Button {
                    presentInstaller()
                } label: {
                    Text("选择软件安装")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(AppStyle.onAccent)
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Button {
                        updater.tryOpenInstaller(fileURL)
                    } label: {
                        Label("直接唤起", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(AppStyle.primaryText)
                    }
                    .buttonStyle(.plain)

                    Button {
                        revealInFiles(fileURL)
                    } label: {
                        Label("在文件 App 中查看", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(AppStyle.primaryText)
                    }
                    .buttonStyle(.plain)
                }

                if shareFailed {
                    Text("没能弹出选择面板。包已放在「文件 - 我的 iPhone - Aurora Music - Updates」，用 AppSync 或 Filza 打开它即可安装。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.gold)
                        .multilineTextAlignment(.center)
                } else if let hint = updater.installHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.gold)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 3) {
                        Text("点上面第一个按钮，在分享面板里选 AppSync / Zebra / Filza")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.tertiaryText)
                            .multilineTextAlignment(.center)
                        Text("若面板里没有任何安装项，说明设备上没装 AppSync / Zebra")
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.tertiaryText)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

        case .failed(let message):
            statusBlock(icon: "exclamationmark.triangle.fill",
                        tint: AppStyle.like,
                        title: "出问题了",
                        message: message)
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await updater.check(force: true) }
            } label: {
                Text("重新检查")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(AppStyle.primaryText)
            }
            .buttonStyle(.plain)

            if case .available(let release) = updater.phase, let url = URL(string: release.html_url) {
                Link(destination: url) {
                    Text("Releases 页面")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(AppStyle.primaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    private func installActions(for release: AppUpdater.Release) -> some View {
        VStack(spacing: 10) {
            Button {
                Task { await updater.install(release) }
            } label: {
                Text("下载并安装")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(AppStyle.onAccent)
            }
            .buttonStyle(.plain)

            if let url = URL(string: release.html_url) {
                Link("或用浏览器下载", destination: url)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    /// 跳到「文件」App 定位到这个安装包。
    ///
    /// 本 App 开了 UIFileSharingEnabled，包就在「我的 iPhone → Aurora Music → Updates」
    /// 里。分享面板没有安装器时，这是把包交出去的最后一条路。
    private func revealInFiles(_ url: URL) {
        guard url.isFileURL else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // shareddocuments 的 path 必须是相对 App 容器根目录的相对路径，
        // 之前这里先塞了绝对路径再覆盖，两种拼法混在一起是错的。
        var relative = url.path
        guard relative.hasPrefix(documents.path) else {
            Log.warn("更新", "安装包不在 Documents 下，无法用文件 App 打开：\(url.path)")
            return
        }
        relative = String(relative.dropFirst(documents.path.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = relative
        guard let target = components.url else { return }
        Log.info("更新", "尝试在文件 App 中打开 \(relative)")
        UIApplication.shared.open(target) { success in
            Log.info("更新", success ? "已跳转到文件 App" : "文件 App 没有响应（\(target.absoluteString)）")
        }
    }

    private func statusBlock(icon: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppStyle.primaryText)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(AppStyle.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 40)
    }
}
