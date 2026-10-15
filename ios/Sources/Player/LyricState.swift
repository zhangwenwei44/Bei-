import Foundation

/// 歌词高亮行 —— 播放时以 **4fps** 变化的高频状态（第三个隔离对象，见 PlayerStore.lyricState）。
///
/// ## 为什么必须拆出来
///
/// ObservableObject 是**整对象粒度**通知：任何一个 @Published 变化都会把
/// 所有订阅该对象的视图全部打脏（SwiftUI 对 ObservableObject 没有
/// 属性级依赖追踪 —— 那是 iOS 17 @Observable 宏才有的能力）。
///
/// `currentLyricIndex` 之前直接挂在 PlayerStore 上：歌词逐行高亮时
/// RootView → MainTabs → **整棵 TabView 树**、四个主页面每秒被重建 4 次，
/// UITabBar 的手势识别被持续打断 —— 表现为
/// 「播放时 TabBar 点不动，暂停就能点」（暂停后歌词不再刷新，重算停止）。
///
/// 拆成独立对象后，只有真正显示歌词的视图（播放页）订阅它，
/// 4fps 的重算被限制在歌词行这一小块 UI 里。
///
/// 与 PlaybackProgress / MiniPlayerState 同一套隔离思路：
/// 高频状态独立成小对象，PlayerStore 只保留低频状态。
final class LyricState: ObservableObject {
    /// 当前高亮的歌词行下标；nil = 无歌词 / 未开始。
    @Published var currentIndex: Int?
}
