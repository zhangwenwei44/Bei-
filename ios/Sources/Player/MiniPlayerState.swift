import SwiftUI

/// 迷你播放条状态 —— 从 PlayerStore 拆出的第二个隔离对象。
///
/// ## 为什么 playback 之外还要再拆一个
///
/// `PlaybackProgress` 解决了 `currentTime`（0.5s/次）的重算，但 PlayerStore 里
/// 还有别的高频属性：
///
/// - `currentLyricIndex` —— **4fps**，歌词逐行高亮时每次 `refreshLyric` 都可能变化
///
/// 只要浮层（`MiniPlayerLayer` / `MiniPlayer`）用 `@EnvironmentObject` 订阅整个
/// `PlayerStore`，这些高频更新就会把浮层每秒重算 4 次。用户反馈的典型症状是
/// **「播放歌曲时底部 TabBar 点不动，暂停就能点」** —— 因为暂停后歌词不再刷新，
/// 重算随之停止，触摸就恢复了。这说明根因是**重算风暴**，不是命中测试拦截。
///
/// ## 这里只放什么
///
/// 浮层真正需要的全是低频状态（切歌 / 播放暂停时才变）：
/// 当前歌曲、是否播放、是否加载中、音源名、多选态。播放进度不在这里 ——
/// 它由 `PlaybackProgress` 单独负责（进度条自己订阅那个）。
///
/// ## 同步时机
///
/// 由 `PlayerStore.syncMiniState()` 在相关状态变更时写入。
/// 与 PlayerStore 是引用关系，读写都是内存操作，开销可忽略。
final class MiniPlayerState: ObservableObject {
    /// 当前播放的歌曲，nil 表示没有在播放的东西。
    @Published var song: Song?
    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false
    /// 当前使用的音源名（官方 / 第三方脚本名）。
    @Published var sourceName: String = ""
    /// 任一页面处于多选模式时隐藏播放条。
    @Published var isMultiSelecting: Bool = false

    /// 播放条是否应该显示。
    var isVisible: Bool { song != nil && !isMultiSelecting }
}
