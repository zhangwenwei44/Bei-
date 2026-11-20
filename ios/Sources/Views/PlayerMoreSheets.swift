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
    case addToPlaylist, sleepTimer, playerStyle, lyricsFontSize, speedPitch, quality, share, source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addToPlaylist: return "添加到酷狗歌单"
        case .sleepTimer:    return "定时关闭"
        case .playerStyle:   return "主题"
        case .lyricsFontSize: return "歌词字号"
        case .speedPitch:    return "调速"
        case .quality:       return "音质选择"
        case .share:         return "分享"
        case .source:        return "音源"
        }
    }
}

/// 🔴 2026-11-16：歌词字号档位。用缩放系数而不是把字号写死在歌词页里，
///    竖屏播放页的歌词模式与全屏歌词页共用同一份设置（都渲染 BigLyricsView）。
enum LyricsFontScale {
    static let key = "aurora.lyricsFontScale"
    static let options: [(String, Double)] = [
        ("小", 0.85), ("标准", 1.0), ("大", 1.18), ("超大", 1.35),
    ]
    static let activeBase: CGFloat = 22
    static let inactiveBase: CGFloat = 15
    static let translationActiveBase: CGFloat = 12
    static let translationInactiveBase: CGFloat = 10
}

struct PlayerMoreSheetView: View {
    let item: PlayerMoreSheet
    /// `.share` 用；其它页面忽略。
    var shareItems: [Any] = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PlayerStore
    @AppStorage("aurora.playerPageTheme") private var playerPageTheme: PlayerPageTheme = .immersiveCover
    /// 🔴 歌词字号：直接写 UserDefaults，歌词页的 BigLyricsView 用同一个 key 订阅，
    ///    在设置页里改完返回就能立刻看到效果，不需要手动传值。
    @AppStorage(LyricsFontScale.key) private var lyricsFontScale: Double = 1.0

    var body: some View {
        Group {
            switch item {
            case .share:
                ShareSheet(items: shareItems)
            case .addToPlaylist:
                addToPlaylistPage
            case .quality:
                // 🔴 2026-11-21：改用贴合内容高度的底部面板 —— 修复 sheet 全屏容器
                //    导致的「上下大片留白」。embeddedInPanel 只输出内容，横条/背景/圆角由面板提供。
                CompactPanelOverlay(onDismiss: { dismiss() }) {
                    QualitySettingsView(embeddedInPanel: true, onDismiss: { dismiss() })
                }
            case .source:
                // 🔴 2026-11-21：同上，音源弹窗改成贴合内容的底部面板（开关 + 拖动排序）。
                CompactPanelOverlay(onDismiss: { dismiss() }) {
                    SourcePickerSheet(onDismiss: { dismiss() })
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
        case .lyricsFontSize:
            return "调整歌词页当前句与其他行的文字大小，立即生效并记住选择"
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

        case .lyricsFontSize:
            lyricsFontPreview
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            divider
            ForEach(Array(LyricsFontScale.options.enumerated()), id: \.offset) { index, option in
                if index > 0 { divider }
                optionRow(title: option.0,
                          selected: abs(lyricsFontScale - option.1) < 0.001) {
                    lyricsFontScale = option.1
                    Haptics.light()
                }
            }

        default:
            EmptyView()
        }
    }

    /// 字号预览：跟着档位实时变化，不用返回歌词页就知道选多大。
    private var lyricsFontPreview: some View {
        let scale = CGFloat(max(0.6, min(1.6, lyricsFontScale)))
        return VStack(spacing: 10) {
            Text("曾梦想仗剑走天涯")
                .font(.system(size: LyricsFontScale.activeBase * scale, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            Text("看一看世界的繁华")
                .font(.system(size: LyricsFontScale.inactiveBase * scale, weight: .medium))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(AppStyle.background, in: RoundedRectangle(cornerRadius: 10))
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

}
