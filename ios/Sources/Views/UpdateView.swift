import SwiftUI
import UIKit

/// 检查更新弹窗：显示版本、Release note，直接下载 IPA 并唤起安装。
struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var updater = AppUpdater.shared
    @State private var isSharePresented = false
    @State private var installURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
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
            .sheet(isPresented: $isSharePresented) {
                if let installURL {
                    ShareSheet(items: [installURL])
                }
            }
            // 进入 .ready 就把包搬到公共目录，用户点按钮时直接可用
            .onChange(of: updater.phase) { phase in
                if case let .ready(file) = phase {
                    installURL = updater.prepareInstall(file)
                }
            }
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
                    .foregroundStyle(.white)
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
                // 可靠路径：分享面板里能选 AppSync / Zebra / Filza
                Button {
                    isSharePresented = true
                } label: {
                    Text("选择软件安装")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Button {
                    updater.tryOpenInstaller(fileURL)
                } label: {
                    Label("直接唤起安装", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppStyle.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(AppStyle.primaryText)
                }
                .buttonStyle(.plain)

                if let hint = updater.installHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.gold)
                        .multilineTextAlignment(.center)
                } else {
                    Text("点第一个按钮后，在分享面板里选 AppSync / Zebra / Filza 安装；包已放到「文件 - 下载」里。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                        .multilineTextAlignment(.center)
                }

                // 分享面板里如果没有安装器，退路是去「文件」App 里把它交给别的应用
                Button {
                    revealInFiles(fileURL)
                } label: {
                    Label("在「文件」App 中查看", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
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
                    .foregroundStyle(.black)
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
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.host = ""
        components.path = documents.path
        // shareddocuments 的 path 必须是相对 App 容器根目录的
        var relative = url.path
        if relative.hasPrefix(documents.path) {
            relative = String(relative.dropFirst(documents.path.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
        }
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
