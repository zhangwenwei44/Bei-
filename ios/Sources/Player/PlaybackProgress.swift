import SwiftUI

/// 播放进度状态 —— 从 PlayerStore 拆出来的独立 ObservableObject。
///
/// ## 为什么要有这个类
///
/// SwiftUI 的 `@EnvironmentObject` / `@ObservedObject` 订阅粒度是**整个对象**，
/// 不是单个属性。只要 `PlayerStore` 里任何一个 `@Published` 发生变化，所有持有
/// `PlayerStore` 的视图都会重算 `body` —— 哪怕它们根本没读那个变化的属性。
///
/// `currentTime` 播放时每 0.5s 变化一次（2 次/秒）。它原本和队列、收藏、歌词
/// 挤在同一个 `PlayerStore` 里，导致 DiscoverView / SearchView / LibraryView /
/// ProfileView 这四个重页面（合计约 3000 行）在播放时被整树重算，
/// 表现为底部 TabBar 卡死、点不动。
///
/// 拆开之后：高频进度只有播放页和 MiniPlayer 进度条订阅，
/// 四个主页面完全不再被进度更新打扰。
///
/// ## 谁该订阅谁
///
/// - **订阅 `playback`（本类）**：播放页进度条、时间标签、歌词滚动、MiniPlayer 进度条。
///   这些确实需要 0.5s 级刷新。
/// - **订阅 `PlayerStore`**：列表高亮、播放按钮、队列等。
///   这些只依赖 `isPlaying` / `current`（切歌时才变），保持低频。
@MainActor
final class PlaybackProgress: ObservableObject {
    /// 当前播放位置（秒）。由 PlayerStore 的节流时间观察器写入。
    @Published var currentTime: Double = 0
    /// 当前曲目总时长（秒）。
    @Published var duration: Double = 0
    /// 已缓冲比例 0...1。
    @Published var bufferedFraction: Double = 0

    /// 播放进度比例 0...1。
    ///
    /// duration 为 0（还没拿到时长）时返回 0，避免除零产生 NaN。
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    /// 把进度重置到初始状态 —— 切歌、停止播放时调用。
    func reset(duration: Double = 0) {
        self.currentTime = 0
        self.duration = duration
        self.bufferedFraction = 0
    }

    /// 定位到指定位置（不经过 PlayerStore 的 seek，供内部逻辑对齐使用）。
    func setCurrentTime(_ value: Double) {
        currentTime = value
    }
}
