import Foundation
import SwiftUI

/// 🔴 2026-11-20：实验室「播放器布局微调」使用的本机参数。
/// 竖屏播放器的歌曲名 / 歌词 / 动作行 / 进度条 / 控件位置与播放按钮大小，
/// 可指定只微调某一个播放器主题；另含全屏歌词页的同类参数。
/// 全部本机保存，不改公开设置页，方便真机上逐项对齐参考图。
final class PlayerLayoutSettings: ObservableObject {
    static let shared = PlayerLayoutSettings()

    /// 当前微调针对哪个播放器主题（0 偏移时对所有主题视觉无影响）。
    @Published var targetThemeRaw: String { didSet { persist() } }
    var targetTheme: PlayerPageTheme {
        PlayerPageTheme(rawValue: targetThemeRaw) ?? .immersiveCover
    }

    // 竖屏播放器
    @Published var titleX: CGFloat { didSet { persist() } }
    @Published var titleY: CGFloat { didSet { persist() } }
    @Published var lyricX: CGFloat { didSet { persist() } }
    @Published var lyricY: CGFloat { didSet { persist() } }
    @Published var actionX: CGFloat { didSet { persist() } }
    @Published var actionY: CGFloat { didSet { persist() } }
    @Published var progressX: CGFloat { didSet { persist() } }
    @Published var progressY: CGFloat { didSet { persist() } }
    @Published var controlsX: CGFloat { didSet { persist() } }
    @Published var controlsY: CGFloat { didSet { persist() } }
    @Published var playSize: CGFloat { didSet { persist() } }

    // 全屏歌词页
    @Published var lyricsTitleX: CGFloat { didSet { persist() } }
    @Published var lyricsTitleY: CGFloat { didSet { persist() } }
    @Published var lyricsTextX: CGFloat { didSet { persist() } }
    @Published var lyricsTextY: CGFloat { didSet { persist() } }
    @Published var lyricsProgressX: CGFloat { didSet { persist() } }
    @Published var lyricsProgressY: CGFloat { didSet { persist() } }
    @Published var lyricsControlsX: CGFloat { didSet { persist() } }
    @Published var lyricsControlsY: CGFloat { didSet { persist() } }
    @Published var lyricsPlaySize: CGFloat { didSet { persist() } }
    @Published var lyricsPlaySizeOverridden: Bool { didSet { persist() } }

    private let defaults = UserDefaults.standard
    private let prefix = "aurora.playerLayout."

    private init() {
        targetThemeRaw = Self.loadString("targetTheme", default: PlayerPageTheme.immersiveCover.rawValue)

        titleX = Self.clamp(Self.load("titleX"), -60, 60)
        titleY = Self.clamp(Self.load("titleY"), -60, 60)
        lyricX = Self.clamp(Self.load("lyricX"), -60, 60)
        lyricY = Self.clamp(Self.load("lyricY"), -60, 60)
        actionX = Self.clamp(Self.load("actionX"), -60, 60)
        actionY = Self.clamp(Self.load("actionY"), -60, 60)
        progressX = Self.clamp(Self.load("progressX"), -60, 60)
        progressY = Self.clamp(Self.load("progressY"), -60, 60)
        controlsX = Self.clamp(Self.load("controlsX"), -60, 60)
        controlsY = Self.clamp(Self.load("controlsY"), -60, 60)
        playSize = Self.clamp(Self.load("playSize", default: 62), 44, 90)

        lyricsTitleX = Self.clamp(Self.load("lyricsTitleX"), -60, 60)
        lyricsTitleY = Self.clamp(Self.load("lyricsTitleY"), -60, 60)
        lyricsTextX = Self.clamp(Self.load("lyricsTextX"), -60, 60)
        lyricsTextY = Self.clamp(Self.load("lyricsTextY"), -60, 60)
        lyricsProgressX = Self.clamp(Self.load("lyricsProgressX"), -60, 60)
        lyricsProgressY = Self.clamp(Self.load("lyricsProgressY"), -60, 60)
        lyricsControlsX = Self.clamp(Self.load("lyricsControlsX"), -60, 60)
        lyricsControlsY = Self.clamp(Self.load("lyricsControlsY"), -60, 60)
        lyricsPlaySize = Self.clamp(Self.load("lyricsPlaySize", default: 52), 44, 90)
        lyricsPlaySizeOverridden = Self.loadBool("lyricsPlaySizeOverridden")
    }

    func reset() {
        targetThemeRaw = PlayerPageTheme.immersiveCover.rawValue
        titleX = 0; titleY = 0
        lyricX = 0; lyricY = 0
        actionX = 0; actionY = 0
        progressX = 0; progressY = 0
        controlsX = 0; controlsY = 0
        playSize = 62
        lyricsTitleX = 0; lyricsTitleY = 0
        lyricsTextX = 0; lyricsTextY = 0
        lyricsProgressX = 0; lyricsProgressY = 0
        lyricsControlsX = 0; lyricsControlsY = 0
        lyricsPlaySize = 52
        lyricsPlaySizeOverridden = false
    }

    private func persist() {
        defaults.set(targetThemeRaw, forKey: prefix + "targetTheme")
        defaults.set(Double(titleX), forKey: prefix + "titleX")
        defaults.set(Double(titleY), forKey: prefix + "titleY")
        defaults.set(Double(lyricX), forKey: prefix + "lyricX")
        defaults.set(Double(lyricY), forKey: prefix + "lyricY")
        defaults.set(Double(actionX), forKey: prefix + "actionX")
        defaults.set(Double(actionY), forKey: prefix + "actionY")
        defaults.set(Double(progressX), forKey: prefix + "progressX")
        defaults.set(Double(progressY), forKey: prefix + "progressY")
        defaults.set(Double(controlsX), forKey: prefix + "controlsX")
        defaults.set(Double(controlsY), forKey: prefix + "controlsY")
        defaults.set(Double(playSize), forKey: prefix + "playSize")
        defaults.set(Double(lyricsTitleX), forKey: prefix + "lyricsTitleX")
        defaults.set(Double(lyricsTitleY), forKey: prefix + "lyricsTitleY")
        defaults.set(Double(lyricsTextX), forKey: prefix + "lyricsTextX")
        defaults.set(Double(lyricsTextY), forKey: prefix + "lyricsTextY")
        defaults.set(Double(lyricsProgressX), forKey: prefix + "lyricsProgressX")
        defaults.set(Double(lyricsProgressY), forKey: prefix + "lyricsProgressY")
        defaults.set(Double(lyricsControlsX), forKey: prefix + "lyricsControlsX")
        defaults.set(Double(lyricsControlsY), forKey: prefix + "lyricsControlsY")
        defaults.set(Double(lyricsPlaySize), forKey: prefix + "lyricsPlaySize")
        defaults.set(lyricsPlaySizeOverridden, forKey: prefix + "lyricsPlaySizeOverridden")
    }

    private static func load(_ key: String, default defaultValue: CGFloat = 0) -> CGFloat {
        let defaults = UserDefaults.standard
        let fullKey = "aurora.playerLayout." + key
        guard defaults.object(forKey: fullKey) != nil else { return defaultValue }
        return CGFloat(defaults.double(forKey: fullKey))
    }

    private static func loadString(_ key: String, default defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: "aurora.playerLayout." + key) ?? defaultValue
    }

    private static func loadBool(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: "aurora.playerLayout." + key)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }
}
