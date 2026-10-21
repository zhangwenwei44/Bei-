import SwiftUI
import UIKit

/// 🔴 v2.5.50：强制更新浮层 —— 启动检测到新版本时全屏盖住 App。
/// 没有关闭按钮（用户要求"不可关闭"）：只能「立即更新」（下载 → 自动弹安装器）
/// 或「用浏览器下载」兜底，更新完成前无法使用 App。
struct ForceUpdateView: View {
    @ObservedObject private var updater = AppUpdater.shared
    /// 已拷到公共目录的安装包路径（分享面板必须用沙盒外那份）
    @State private var sharedURL: URL?
    /// 安装器只自动弹一次，失败后由按钮手动重弹
    @State private var autoPresented = false
    @State private var shareFailed = false

    var body: some View {
        ZStack {
            AppStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(AppStyle.accent)
                Text("发现新版本")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                    .padding(.top, 14)

                if let release = updater.forceRelease {
                    Text("最新版本 \(release.name ?? release.tag_name)，当前 \(updater.versionText)")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.secondaryText)
                        .padding(.top, 8)

                    let notes = AppUpdater.notes(from: release.body, limit: 6)
                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(AppStyle.accent.opacity(0.6))
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 6)
                                    Text(line)
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppStyle.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 36)
                    }
                }

                Spacer()

                actionArea
                    .padding(.horizontal, 32)
                    .padding(.bottom, max(UIScreen.main.bounds.height * 0.06, 40))
            }
        }
        // 下载完成（或进来时已是 ready）：拷公共目录 + 自动弹安装器
        .onChange(of: updater.phase) { phase in
            if case let .ready(file) = phase { enterReadyState(file) }
        }
        .onAppear {
            if case let .ready(file) = updater.phase { enterReadyState(file) }
        }
    }

    // MARK: 状态区

    @ViewBuilder
    private var actionArea: some View {
        switch updater.phase {
        case .downloading(let progress):
            VStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("正在下载更新… \(Int(progress * 100))%")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
            }

        case .ready:
            VStack(spacing: 10) {
                ProgressView()
                Text(shareFailed ? "安装器没有自动弹出，点下面的按钮重试"
                                 : "下载完成，正在弹出安装器…")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                if shareFailed {
                    reinstallButton
                }
            }

        case .failed(let message):
            VStack(spacing: 14) {
                Text("更新失败：\(message)")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.secondaryText)
                    .multilineTextAlignment(.center)
                reinstallButton
                browserButton
            }

        default:
            // .available / .checking
            VStack(spacing: 14) {
                Button {
                    startInstall()
                } label: {
                    Text(updater.phase.isBusy ? "正在检查…" : "立即更新")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(updater.phase.isBusy)
                .opacity(updater.phase.isBusy ? 0.6 : 1)

                browserButton
            }
        }
    }

    private var reinstallButton: some View {
        Button {
            if let target = sharedURL {
                shareFailed = !IPAInstaller.presentShareSheet(for: target)
            } else {
                startInstall()
            }
            Haptics.light()
        } label: {
            Text(sharedURL == nil ? "重试下载" : "重新弹出安装器")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 兜底：直接打开 GitHub Release 页用浏览器下载
    private var browserButton: some View {
        Button {
            if let release = updater.forceRelease,
               let url = URL(string: release.html_url) {
                UIApplication.shared.open(url)
            }
            Haptics.light()
        } label: {
            Text("用浏览器下载")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppStyle.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.plain)
    }

    // MARK: 行为

    private func startInstall() {
        guard let release = updater.forceRelease else { return }
        Task { await updater.install(release) }
    }

    private func enterReadyState(_ file: URL) {
        let target = updater.prepareInstall(file)
        sharedURL = target
        guard !autoPresented else { return }
        autoPresented = true
        // 稍等一拍让界面渲染完，否则 present 会撞上视图更新被吞
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            shareFailed = !IPAInstaller.presentShareSheet(for: target)
        }
    }
}
