import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

// MARK: - 🔴 2026-11-15 第二十三轮：播放器「更多」里每个按钮的真实落地页
//
// 全部走**同一个 `.sheet(item:)`**：iOS 15 链式多个 `.sheet(isPresented:)`
// 只有最后一个生效（项目既有红线），用 Identifiable 枚举统一收口。
// 竖屏播放页与歌词页共用这套页面，行为完全一致。

enum PlayerMoreSheet: String, Identifiable {
    case addToPlaylist, sleepTimer, playerStyle, cast, speedPitch, quality, share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addToPlaylist: return "添加到酷狗歌单"
        case .sleepTimer:    return "定时关闭"
        case .playerStyle:   return "播放器样式"
        case .cast:          return "投播"
        case .speedPitch:    return "调速·升降调"
        case .quality:       return "音质选择"
        case .share:         return "分享"
        }
    }
}

struct PlayerMoreSheetView: View {
    let item: PlayerMoreSheet
    /// `.share` 用；其它页面忽略。
    var shareItems: [Any] = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PlayerStore
    @AppStorage("aurora.playerPageTheme") private var playerPageTheme: PlayerPageTheme = .immersiveCover
    @State private var routeName: String = "本机扬声器"

    var body: some View {
        Group {
            switch item {
            case .share:
                ShareSheet(items: shareItems)
            case .addToPlaylist:
                addToPlaylistPage
            case .quality:
                CompatNavigationStack {
                    QualitySettingsView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { dismiss() }
                            }
                        }
                }
            default:
                settingsPage
            }
        }
    }

    // MARK: - 加到酷狗歌单（真实写云端歌单）

    @ViewBuilder
    private var addToPlaylistPage: some View {
        if let song = store.current {
            KugouPlaylistPicker(songs: [song], title: "添加到酷狗歌单")
        } else {
            CompatNavigationStack {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34))
                        .foregroundStyle(AppStyle.tertiaryText)
                    Text("当前没有正在播放的歌曲")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppStyle.background)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .kugouNavigationBarBackground()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - 定时关闭 / 播放器样式 / 投播 / 调速

    private var settingsPage: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let hint = hintText {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 10)
                    }
                    VStack(spacing: 0) { rows }
                        .background(AppStyle.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
            .background(AppStyle.background)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .kugouNavigationBarBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { refreshRoute() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                refreshRoute()
            }
        }
    }

    private var hintText: String? {
        switch item {
        case .sleepTimer:
            if let remain = store.sleepTimerRemaining {
                let mins = max(1, Int(ceil(remain / 60)))
                return "已开启，约 \(mins) 分钟后自动暂停播放"
            }
            return "到时间后自动暂停播放，不影响已下载歌曲"
        case .speedPitch:
            return "变速会同时改变音调，切歌后依然生效；1.0× 为原速"
        case .cast:
            return "当前输出：\(routeName)。点下方按钮选择 AirPlay / 蓝牙设备"
        case .playerStyle:
            return "切换后竖屏播放页立即换样式，并记住你的选择"
        default:
            return nil
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch item {
        case .sleepTimer:
            optionRow(title: "10 分钟", selected: false) { store.setSleepTimer(minutes: 10); dismiss() }
            divider
            optionRow(title: "20 分钟", selected: false) { store.setSleepTimer(minutes: 20); dismiss() }
            divider
            optionRow(title: "30 分钟", selected: false) { store.setSleepTimer(minutes: 30); dismiss() }
            divider
            optionRow(title: "60 分钟", selected: false) { store.setSleepTimer(minutes: 60); dismiss() }
            divider
            optionRow(title: "关闭定时", selected: store.sleepTimerEnd == nil,
                      destructive: store.sleepTimerEnd != nil) { store.setSleepTimer(minutes: 0); dismiss() }

        case .playerStyle:
            ForEach(Array(PlayerPageTheme.cardOrder.enumerated()), id: \.element.id) { index, theme in
                if index > 0 { divider }
                optionRow(title: theme.title, selected: playerPageTheme == theme) {
                    playerPageTheme = theme
                    Haptics.light()
                }
            }

        case .speedPitch:
            let options: [(String, Float)] = [("0.75×", 0.75), ("1.0× 原速", 1.0),
                                              ("1.25×", 1.25), ("1.5×", 1.5), ("2.0×", 2.0)]
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { divider }
                optionRow(title: option.0, selected: abs(store.playbackRate - option.1) < 0.001) {
                    store.setPlaybackRate(option.1)
                    Haptics.light()
                }
            }

        case .cast:
            HStack(spacing: 12) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 22))
                    .foregroundStyle(AppStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择播放设备").font(.system(size: 15, weight: .medium))
                    Text(routeName).font(.system(size: 12)).foregroundStyle(AppStyle.tertiaryText)
                }
                Spacer(minLength: 0)
                AirPlayRouteButton()
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

        default:
            EmptyView()
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }

    private func optionRow(title: String,
                           selected: Bool,
                           destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(destructive ? Color.red : AppStyle.primaryText)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppStyle.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        routeName = session.currentRoute.outputs.first?.portName ?? "本机扬声器"
    }
}

/// 系统 AirPlay / 蓝牙输出选择按钮（MPVolumeView 自带的 route button）。
private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        view.tintColor = UIColor.systemBlue
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
