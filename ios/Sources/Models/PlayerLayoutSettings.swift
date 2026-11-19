import Foundation
import SwiftUI

/// 🔴 2026-11-19：实验室「播放器布局微调」使用的本机参数。
/// 只作用于竖屏播放器的歌曲名 / 歌词 / 动作行 / 进度条 / 控件位置与播放按钮大小。
/// 全部本机保存，不改公开设置页，方便真机上逐项对齐参考图。
final class PlayerLayoutSettings: ObservableObject {
    static let shared = PlayerLayoutSettings()

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

    private let defaults = UserDefaults.standard
    private let prefix = "aurora.playerLayout."

    private init() {
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
    }

    func reset() {
        titleX = 0; titleY = 0
        lyricX = 0; lyricY = 0
        actionX = 0; actionY = 0
        progressX = 0; progressY = 0
        controlsX = 0; controlsY = 0
        playSize = 62
    }

    private func persist() {
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
    }

    private static func load(_ key: String, default defaultValue: CGFloat = 0) -> CGFloat {
        let defaults = UserDefaults.standard
        let fullKey = "aurora.playerLayout." + key
        guard defaults.object(forKey: fullKey) != nil else { return defaultValue }
        return CGFloat(defaults.double(forKey: fullKey))
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }
}
