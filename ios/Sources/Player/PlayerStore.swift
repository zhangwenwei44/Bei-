import AVFoundation
import MediaPlayer
import Network
import SwiftUI
import UIKit

/// 播放核心：队列、在线地址解析、歌词、锁屏控制、历史。
final class PlayerStore: ObservableObject {
    // MARK: 队列

    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = -1
    @Published var queueID: String? = nil
    @Published var mode: PlaybackMode = .order

    // MARK: 播放状态

    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    /// 播放中缓冲等待（有 URL 但还没足够数据开始播/继续播）。
    /// 和 isLoading 区别：isLoading = 解析 URL，isBuffering = AVPlayer 在等网络数据。
    @Published private(set) var isBuffering = false
    @Published private(set) var playbackError: String?
    @Published private(set) var sourceName: String = ""
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedFraction: Double = 0
    @Published private(set) var bitrateLabel: String = ""

    /// 网络状态：true=有网，false=断网。
    @Published private(set) var isNetworkAvailable = true
    /// true=弱网（cellular/expensive + high latency），UI 可以给个提示但不强制降级。
    @Published private(set) var isWeakNetwork = false
    /// true=WiFi 且非低数据模式 → 允许自动预缓存；蜂窝/低数据模式 → 关闭预缓存防偷流量。
    @Published private(set) var isWiFiNetwork = true
    /// 断网前是否在播放 —— 恢复时据此自动恢复播放。
    private var wasPlayingBeforeNetworkLoss = false

    // MARK: 歌词与视觉

    @Published private(set) var lyrics: [LyricLine] = []
    /// 从歌词剥离出来的词曲/编曲/制作人等元数据。
    @Published private(set) var lyricMetadata: [String: String] = [:]
    @Published private(set) var currentLyricIndex: Int?
    @Published private(set) var artwork: UIImage?
    /// 当前歌手的写真，播放页背景用。拿不到时界面自己兜底。
    @Published private(set) var artistPhoto: UIImage?
    @Published private(set) var currentPalette = ArtworkPaletteEngine.palette(for: nil, seed: "-")
    @Published var showTranslation = false

    // MARK: - 多选共享状态

    /// 任何页面进入多选模式时置 true —— RootView 据此隐藏浮动 MiniPlayer，避免遮挡底部操作栏。
    @Published var isAnyMultiSelecting = false

    // MARK: 交互

    @Published private(set) var isLiked = false
    @Published var isQueuePresented = false
    /// 睡眠定时结束时间，nil 表示未设置。
    @Published var sleepTimerEnd: Date?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    /// 每个 AVPlayerItem 的 KVO 观察 token（替换 item 时必须先 invalidate，不然会 crash）。
    private var itemObservers: [NSKeyValueObservation] = []
    private var shuffleHistory: [Int] = []
    private var failedHosts = Set<String>()
    /// 换源重试限制：同一首歌最多自动重试 1 次，防止把音源打熔断
    private var recoverySongID: String?
    private var recoveryAttempts = 0
    private var preparingTask: Task<Void, Never>?
    /// 下一首预加载（只创建 AVPlayerItem 让 AVAsset 建立连接，不 attach，不耗太多带宽）。
    private var preloadedItem: AVPlayerItem?
    private var preloadedForSongID: String?
    private var lastPreloadTriggerTime: Double = 0
    /// 解析过的播放地址缓存（key = song.id, value = (url, thirdParty, timestamp)）。
    /// 同一首歌在短时间内被 prepare 多次（AVPlayer stall 重试、SwiftUI body 重新计算等）
    /// 时直接用缓存，不再重复走 SourceResolver。
    /// CDN 地址是分时 token，有效窗口约 2 小时，缓存 15 分钟就够覆盖 99% 的场景。
    private struct ResolvedEntry { let url: URL; let thirdParty: Bool; let at: Date }
    private var resolvedURLCache: [String: ResolvedEntry] = [:]
    private let resolvedURLCacheTTL: TimeInterval = 15 * 60
    private var artworkTaskID: String?
    private var artistPhotoTaskID: String?
    private var lyricTaskID: String?
    private var lastNowPlayingSecond = -1
    /// @Published currentTime 节流桶 —— 只在 0.5s 边界变化时 publish，减少 SwiftUI body 重建。
    private var lastPublishedHalfSecond = -1
    /// bufferedFraction 改由 AVPlayerItem KVO loadedTimeRanges 驱动（不再轮询），此变量已弃用。
    // private var lastPublishedQuarterSecond = -1
    /// stall 自动恢复定时器 — 15 秒内没恢复就重新 attach
    private var stallRecoveryTimer: Timer?
    private var stalledSongID: String?

    var current: Song? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }
    var sleepTimerRemaining: TimeInterval? {
        guard let sleepTimerEnd else { return nil }
        return max(0, sleepTimerEnd.timeIntervalSinceNow)
    }

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        installTimeObserver()
        installNotifications()
        installRemoteCommands()
        installNetworkMonitor()
        installQualityMonitor()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        itemObservers.forEach { $0.invalidate() }
        pathMonitor.cancel()
    }

    // MARK: - 网络监听

    private let pathMonitor = NWPathMonitor()

    private func installNetworkMonitor() {
        pathMonitor.start(queue: .global(qos: .utility))
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isAvailable = path.status == .satisfied
            let isExpensive = path.isExpensive  // cellular/personal hotspot
            // WiFi 门控：必须是 WiFi 接口 + 非低数据模式 → 才允许自动预缓存
            let isWiFi = path.usesInterfaceType(.wifi) && !path.isConstrained
            let isWeak = isExpensive || path.availableInterfaces.count <= 0

            Task { @MainActor in
                if isAvailable != self.isNetworkAvailable {
                    if !isAvailable {
                        // 断网 → 记住状态，暂停
                        self.wasPlayingBeforeNetworkLoss = self.isPlaying
                        if self.isPlaying { self.pause() }
                        self.isBuffering = false
                        Log.warn("网络", "网络中断，暂停播放")
                    } else {
                        // 恢复 → 如果断网前在播，自动恢复
                        if self.wasPlayingBeforeNetworkLoss, let _ = self.player.currentItem {
                            self.player.play()
                            self.objectWillChange.send()
                            Log.info("网络", "网络恢复，自动续播")
                        }
                        self.wasPlayingBeforeNetworkLoss = false
                    }
                }
                self.isNetworkAvailable = isAvailable
                self.isWeakNetwork = isAvailable && isWeak
                self.isWiFiNetwork = isAvailable && isWiFi
            }
        }
    }

    // MARK: - 音质切换

    /// 待恢复的 seek 位置（mid-song 音质切换时设置，attach 后 item readyToPlay 时消费）。
    /// 不用硬编码 sleep —— AVPlayerItem 真正 ready 了才 seek，避免弱网下 seek 失败或覆盖用户手动操作。
    private var pendingQualitySwitchSeek: Double?

    /// 监听 SourceStore.quality 变化，正在播放就用新音质重新解析当前歌曲。
    private func installQualityMonitor() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in SourceStore.shared.$quality.values {
                // 跳过初始化时的第一次（和当前值相同）
                // prepare() 里已经读了最新 quality，所以每次 prepare 都会用新音质
                // 这里只需要处理 mid-playback 切换 —— 重新解析 URL 并保留 seek 位置
                if let current, self.player.currentItem != nil, !self.isLoading {
                    Log.info("播放", "音质切换，重新解析当前歌曲 URL")
                    self.pendingQualitySwitchSeek = self.currentTime
                    self.prepare(autoplay: self.isPlaying)
                    // attach 完成后 item readyToPlay 时自动消费 pendingQualitySwitchSeek
                }
            }
        }
    }

    /// App 启动时调用。
    func bootstrap() {
        DownloadManager.shared.bootstrap()
    }

    // MARK: - 队列操作

    /// 用一批歌曲替换队列并从指定位置开始播放。
    func play(_ songs: [Song], startAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        queue = songs
        currentIndex = min(max(0, index), songs.count - 1)
        shuffleHistory = []
        prepare(autoplay: true)
    }

    func append(_ songs: [Song]) {
        queue.append(contentsOf: songs)
    }

    func playNow(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let position = currentIndex >= 0 ? currentIndex + 1 : 0
        queue.insert(contentsOf: songs, at: position)
        currentIndex += 1
        prepare(autoplay: true)
    }

    func remove(at offsets: IndexSet) {
        for offset in offsets.sorted(by: >) where queue.indices.contains(offset) {
            queue.remove(at: offset)
            if offset < currentIndex { currentIndex -= 1 }
        }
        if queue.isEmpty { stopAll(); return }
        if !queue.indices.contains(currentIndex) {
            currentIndex = min(max(0, currentIndex), queue.count - 1)
            prepare(autoplay: false)
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
        if let first = offsets.first {
            if currentIndex == first { currentIndex = destination > first ? destination - 1 : destination }
            else if currentIndex > first, currentIndex < destination { currentIndex -= 1 }
            else if currentIndex < first, currentIndex >= destination { currentIndex += 1 }
        }
    }

    func clear() {
        stopAll()
    }

    func stopAll() {
        preparingTask?.cancel()
        preloadedItem = nil
        preloadedForSongID = nil
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        currentIndex = -1
        isPlaying = false
        isLoading = false
        isBuffering = false
        currentTime = 0
        duration = 0
        lyrics = []
        currentLyricIndex = nil
        playbackError = nil
        sourceName = ""
        artwork = nil
        artistPhoto = nil
        currentPalette = ArtworkPaletteEngine.palette(for: nil, seed: "-")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - 加载与播放

    /// 一次播放地址解析的结果。
    private struct Outcome {
        var url: URL?
        var name: String
        var label: String
        var isThirdParty: Bool
    }

    private func prepare(autoplay: Bool) {
        guard let song = current else { return }
        preparingTask?.cancel()

        lyrics = []
        currentLyricIndex = nil
        currentTime = 0
        duration = song.duration
        bufferedFraction = 0
        bitrateLabel = ""
        playbackError = nil
        isLiked = LibraryStore.shared.isFavorite(song)
        isLoading = true
        isBuffering = false
        artistPhoto = nil
        refreshArtwork(for: song)
        loadLyrics(for: song)

        // 缓存命中 —— 短时间内切回来或 stall 后重试同一首歌，不再重新解析
        let now = Date()
        if let cached = resolvedURLCache[song.id],
           now.timeIntervalSince(cached.at) < resolvedURLCacheTTL {
            Log.info("播放", "缓存命中，直接用上次解析的 URL（\(song.title.prefix(20))）")
            isLoading = false
            attach(url: cached.url, thirdParty: cached.thirdParty, autoplay: autoplay)
            return
        }

        let excluded = failedHosts
        let task = Task { [weak self] in
            guard let self else { return }
            // 解析结果在这里算完并冻结成 let，再交给后面的闭包。
            // 之前是一组 var 局部变量被 MainActor.run 闭包捕获，
            // 并发检查报「reference to captured var」，Swift 6 语言模式下直接是错误。
            let outcome: Outcome
            if let local = DownloadManager.shared.localURL(for: song) {
                outcome = Outcome(url: local, name: "已下载", label: "本地", isThirdParty: false)
            } else if let audio = await SourceResolver.resolve(song: song,
                                                                 quality: SourceStore.shared.quality,
                                                                 excludedHosts: excluded) {
                outcome = Outcome(url: audio.url,
                                  name: audio.sourceName,
                                  label: audio.quality.title,
                                  isThirdParty: audio.isThirdParty)
            } else {
                outcome = Outcome(url: nil, name: "", label: "", isThirdParty: false)
            }

            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard let self, self.current?.id == song.id else { return }
                    self.isLoading = false
                }
                return
            }
            // 音源吐回来的 http 地址在设备上会被 ATS 直接拦掉（表现就是
            // 「解析成功却播放失败」），能升级 https 的先升级。
            // 注意 MainActor.run 的闭包里不能 await，升级要在进主线程之前做完。
            let finalURL: URL?
            if let url = outcome.url, !url.isFileURL {
                finalURL = await Self.upgradeToHTTPS(url)
            } else {
                finalURL = outcome.url
            }
            await MainActor.run { [weak self] in
                guard let self, self.current?.id == song.id else { return }
                self.isLoading = false
                self.sourceName = outcome.name
                self.bitrateLabel = outcome.label
                guard let url = finalURL else {
                    self.playbackError = "这首歌暂时无法播放，去「我的 - 音源」看看"
                    self.player.pause()
                    self.isPlaying = false
                    return
                }
                self.attach(url: url, thirdParty: outcome.isThirdParty, autoplay: autoplay)
                // 解析成功，写入缓存（CDN 分时 token 15 分钟内不会过期）
                self.resolvedURLCache[song.id] = ResolvedEntry(url: url, thirdParty: outcome.isThirdParty, at: Date())
                // 缓存只留最近 10 条，防止内存泄漏
                if self.resolvedURLCache.count > 10 {
                    let oldest = self.resolvedURLCache.sorted { $0.value.at < $1.value.at }.first?.key
                    if let oldest { self.resolvedURLCache.removeValue(forKey: oldest) }
                }
            }
        }
        preparingTask = task
    }

    /// http → https 升级。先用 Range GET 探测 https 是否可用（HEAD 有一部分 CDN 不支持），
    /// 通了就换 https；不通保留原地址交给 AVPlayer，不额外增加失败面。
    private static func upgradeToHTTPS(_ url: URL) async -> URL {
        guard url.scheme?.lowercased() == "http",
              let secure = URL(string: url.absoluteString.replacingOccurrences(of: "http://", with: "https://")) else {
            return url
        }
        var request = URLRequest(url: secure)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = 6
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let code = (response as? HTTPURLResponse)?.statusCode,
           code == 200 || code == 206 {
            Log.info("音源解析", "播放地址已从 http 升级为 https：\(secure.host ?? "")")
            return secure
        }
        Log.warn("音源解析", "https 探测不通（\(secure.host ?? "")），保留原 http 地址")
        return url
    }

    private func attach(url: URL, thirdParty: Bool, autoplay: Bool) {
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()

        // 如果刚好有 preloaded item 对应当前歌曲（切到了被预加载的那首），直接用它 ——
        // AVAsset 已经预建 CDN 连接，切歌更快；preloadedItem 还没 attach 给任何 player，可以安全复用。
        let item: AVPlayerItem
        if let preloadedItem, preloadedForSongID == current?.id {
            item = preloadedItem
            self.preloadedItem = nil
            self.preloadedForSongID = nil
            Log.info("预加载", "复用预加载好的 item，跳过新建")
        } else {
            item = AVPlayerItem(url: url)
            // 前置缓冲 10 秒 —— 让 AVPlayer 攒够一段数据再开始播，弱网下首帧更快出来
            item.preferredForwardBufferDuration = 10
        }

        player.replaceCurrentItem(with: item)
        itemThirdParty = thirdParty
        // 这次能播，之前拉黑的节点就放回候选池
        failedHosts = []

        // KVO: 缓冲状态 — Swift 6 strict concurrency：KVO 闭包非隔离，[weak self] 捕获后不能在 Task 内直接用 self，
        // 必须先在闭包内 guard 解包再传给 Task。
        // KVO: loadedTimeRanges —— 缓冲范围变化时才计算 bufferedFraction，
        // 不再在 time observer 里每 0.25s 轮询 loadedTimeRanges（主线程开销）
        itemObservers.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                let total = item.duration.seconds
                if total.isFinite, total > 0 {
                    let range = item.loadedTimeRanges.first?.timeRangeValue
                    let buffer = range.map { Double($0.duration.seconds / total) } ?? 0
                    self.bufferedFraction = buffer.isFinite ? max(0, min(1, buffer)) : 0
                }
            }
        })
        itemObservers.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isBuffering = item.isPlaybackBufferEmpty || !(item.isPlaybackLikelyToKeepUp)
            }
        })
        itemObservers.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.isPlaybackLikelyToKeepUp { self.isBuffering = false }
            }
        })
        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                if item.status == .readyToPlay {
                    self.isBuffering = false
                    // 音质切换 mid-song 场景：attach 完成 + item ready → 恢复 seek 位置
                    if let pending = self.pendingQualitySwitchSeek, pending > 0 {
                        self.player.seek(to: CMTime(seconds: pending, preferredTimescale: 600))
                        self.currentTime = pending
                        self.pendingQualitySwitchSeek = nil
                        Log.info("播放", "音质切换 seek 恢复到 \(pending)s")
                    }
                }
            }
        })

        if autoplay {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        updateNowPlaying()
        triggerNextSongPreload()
    }

    private var itemThirdParty = false

    // MARK: - 下一首预加载（内存临时，退出清空；仅 WiFi 非低数据模式）

    /// 自动预加载下一首音频到内存，不写磁盘 —— App 退出/杀后台自动清空。
    /// 触发时机：当前歌曲剩余 <= 8 秒（二次校验点），如果还没预加载好就触发。
    /// 门控顺序：用户手动开关（@AppStorage）→ WiFi 非低数据模式 —— 关任何一个都跳过。
    /// 只预加载 1 首，控制内存。切歌时 attach() 会优先复用预加载好的 item 实现无缝。
    private func triggerNextSongPreload() {
        // 0. 用户手动开关（优先级最高）
        let defaults = UserDefaults.standard
        let userEnabled = defaults.object(forKey: "aurora.autoPrecache") as? Bool ?? true
        guard userEnabled else { return }
        // 1. WiFi 门控：蜂窝/低数据模式直接关，防偷流量
        guard isWiFiNetwork else { return }
        // 仅预加载 1 首（内存临时），如果已经在预加载同一首就跳过
        guard queue.indices.contains(currentIndex + 1),
              let next = queue[currentIndex + 1] as Song?,
              !next.isLocal else { return }  // 本地歌曲不用预加载
        if preloadedForSongID == next.id { return }  // 已经预加载好了

        // 触发时机：剩余 <= 8 秒
        let remaining = duration - currentTime
        guard duration > 0, remaining <= 8, remaining >= 0 else { return }
        // 防频繁触发：同一首下一首 3 秒内只触发一次
        let now = currentTime
        if now - lastPreloadTriggerTime < 3 { return }
        lastPreloadTriggerTime = now

        // 有 URL 缓存直接用（CDN 分时 token 15 分钟内有效）
        if let cached = resolvedURLCache[next.id] {
            preloadedItem = AVPlayerItem(url: cached.url)
            preloadedItem?.preferredForwardBufferDuration = 10  // 跟 attach 里一致，让 AVAsset 预建足够连接
            preloadedForSongID = next.id
            Log.info("预加载", "命中缓存，下一首预热：\(next.title.prefix(20))")
            return
        }

        // 没有缓存 → 异步解析（低优先级，不阻塞播放）
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let audio = await SourceResolver.resolve(
                song: next,
                quality: SourceStore.shared.quality,
                excludedHosts: self.failedHosts
            ) else {
                Log.warn("预加载", "下一首 URL 解析失败：\(next.title.prefix(20))")
                return
            }
            let assetURL: URL
            if !audio.url.isFileURL {
                assetURL = await Self.upgradeToHTTPS(audio.url)
            } else {
                assetURL = audio.url
            }
            await MainActor.run {
                // 切歌前预加载才有用 —— 如果已经切到下一首或更远就丢了
                guard self.currentIndex + 1 < self.queue.count,
                      self.queue[self.currentIndex + 1].id == next.id else { return }
                self.preloadedItem = AVPlayerItem(url: assetURL)
                self.preloadedItem?.preferredForwardBufferDuration = 10
                self.preloadedForSongID = next.id
                // 写入缓存方便下次 prepare/stall 恢复直接用
                self.resolvedURLCache[next.id] = ResolvedEntry(url: assetURL, thirdParty: audio.isThirdParty, at: Date())
                Log.info("预加载", "下一首预热完成：\(next.title.prefix(20))")
            }
        }
    }

    func play() {
        guard player.currentItem != nil else {
            prepare(autoplay: true)
            return
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let target = max(0, min(seconds, upper))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        currentTime = target
        refreshLyric()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func step(_ direction: Int, automatic: Bool = false) {
        guard !queue.isEmpty else { return }
        if automatic, mode == .single {
            seek(to: 0)
            play()
            return
        }
        if mode == .shuffle, queue.count > 1 {
            if automatic, let last = shuffleHistory.last {
                shuffleHistory.removeLast()
                currentIndex = last
                prepare(autoplay: true)
                return
            }
            if !automatic { shuffleHistory.append(currentIndex) }
            var candidate = currentIndex
            while candidate == currentIndex { candidate = Int.random(in: 0..<queue.count) }
            currentIndex = candidate
            prepare(autoplay: true)
            return
        }
        let count = queue.count
        currentIndex = (currentIndex + direction + count) % count
        prepare(autoplay: true)
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        prepare(autoplay: true)
    }

    // MARK: - 收藏

    func toggleFavorite() {
        guard let song = current else { return }
        isLiked = LibraryStore.shared.toggleFavorite(song)
        Haptics.light()
    }

    // MARK: - 睡眠定时

    func setSleepTimer(minutes: Int) {
        if minutes <= 0 {
            sleepTimerEnd = nil
        } else {
            sleepTimerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    // MARK: - 歌词

    private func loadLyrics(for song: Song) {
        lyricTaskID = song.id
        guard !song.kugouHash.isEmpty else { return }
        Task { [weak self] in
            let lrc = await KugouClient.shared.lyric(hash: song.kugouHash, duration: song.duration)
            guard let lrc, !lrc.isEmpty else { return }
            let result = LRCParser.parse(lrc)
            guard !result.lines.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lyricTaskID == song.id else { return }
                self.lyrics = result.lines
                self.lyricMetadata = result.metadata
                self.refreshLyric()
            }
        }
    }

    private func refreshLyric() {
        refreshLyric(at: currentTime)
    }

    /// 直接用传入的时间，不依赖 @Published currentTime —— 时间观察器里用这个保持精准对齐，
    /// 因为 currentTime 被节流到 0.5s 一桶，内部的 0.05s 原始时间更准。
    private func refreshLyric(at time: Double) {
        let found = LRCParser.index(at: time, in: lyrics)
        if found != currentLyricIndex { currentLyricIndex = found }
    }

    // MARK: - 封面与取色

    /// 拉当前歌手的写真给播放页当背景。多人合唱只搜主歌手；
    /// 失败就静默，播放页退回封面取色渐变。
    private func loadArtistPhoto(for song: Song) {
        artistPhotoTaskID = song.id
        let lead = song.artist.components(separatedBy: CharacterSet(charactersIn: "、/&，,"))
            .first?
            .trimmingCharacters(in: .whitespaces) ?? song.artist
        guard !lead.isEmpty else { return }
        Task { [weak self] in
            guard let url = await KugouClient.shared.artistPhoto(name: lead, title: song.title) else { return }
            guard let image = await CoverLoader.download(url) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.artistPhotoTaskID == song.id else { return }
                self.artistPhoto = image
            }
        }
    }

    private func refreshArtwork(for song: Song) {
        artworkTaskID = song.id
        let seed = "\(song.artist)-\(song.title)"
        currentPalette = ArtworkPaletteEngine.palette(for: nil, seed: seed)
        // 关键：每首歌必须加载自己的封面。之前这里有个早返回：
        // if let current = artwork { ... return }
        // 导致切歌时如果 artwork 已经有值（上一首歌的封面），
        // 就永远不加载当前歌的封面——所有歌都显示同一张图。
        Task { [weak self] in
            let image = await Self.loadArtwork(for: song)
            guard let image else { return }
            await MainActor.run { [weak self] in
                guard let self, self.artworkTaskID == song.id else { return }
                self.artwork = image
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.currentPalette = ArtworkPaletteEngine.palette(for: image, seed: seed)
                }
                self.updateNowPlaying()
            }
        }
    }

    private static func loadArtwork(for song: Song) async -> UIImage? {
        // 榜单歌曲不带封面地址，先按专辑 id 联网补一次
        var url = song.artworkURL
        if url == nil {
            url = await CoverResolver.shared.resolveCover(for: song.coverFallbackKeys)
        }
        if let url {
            return await CoverLoader.download(url)
        }
        guard let url = DownloadManager.shared.localURL(for: song) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let value = try? await item.load(.value), let image = value as? UIImage {
                return image
            }
        }
        return nil
    }

    // MARK: - 进度与通知

    private func installTimeObserver() {
        // ⚠️ 从 0.05s → 0.25s（4fps）—— 歌词 4fps 视觉完全流畅，
        // 但主线程工作量立刻砍掉 4×。之前 0.05s × 每秒 20 次回调里：
        // refreshLyric 每次扫完 100 行歌词（O(n)）+ bufferedFraction 读 loadedTimeRanges
        // + currentTime 节流桶比较 —— 叠加起来和 ScrollGesture 渲染抢 CPU 就卡顿。
        // 0.25s 足够歌词精准对齐（每首歌每行歌词持续至少 0.5s）。
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let rawTime = time.seconds.isFinite ? max(0, time.seconds) : 0

            // 节流 @Published currentTime：0.5 秒刷一次（2 次/秒），避免 UI 高频重建
            let halfSecondBucket = Int(rawTime * 2)
            if halfSecondBucket != self.lastPublishedHalfSecond {
                self.lastPublishedHalfSecond = halfSecondBucket
                self.currentTime = rawTime
            }

            // duration：AVPlayerItem ready 后才会有精准值，即时 publish（变化只在切歌时发生一次）
            if let item = self.player.currentItem {
                let total = item.duration.seconds
                if total.isFinite, total > 0, total != self.duration { self.duration = total }
            }

            // 歌词刷新继续用原始时间 —— LRCParser.index 现在是二分 O(log n)，
            // 4fps 下每次只做 7 次比较（100 行歌词），完全不是瓶颈
            self.refreshLyric(at: rawTime)

            if let end = self.sleepTimerEnd, Date() >= end {
                self.sleepTimerEnd = nil
                self.pause()
            }
            // 每秒刷新一次锁屏信息 + 检查下一首预加载
            let wholeSecond = Int(rawTime)
            if wholeSecond != self.lastNowPlayingSecond {
                self.lastNowPlayingSecond = wholeSecond
                self.updateNowPlaying()
                self.triggerNextSongPreload()
            }
        }
    }

    private func installNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                            object: nil,
                                            queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
            self.recordHistory()
            self.step(1, automatic: true)
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable, self.isPlaying else { return }
            self.pause()
        })

        // 电话/Siri/闹钟打断 → 自动恢复
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                Log.info("播放", "AVAudioSession interruption 开始，暂停")
                if self.isPlaying { self.pause() }
            case .ended:
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = (opts & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0
                Log.info("播放", "AVAudioSession interruption 结束，shouldResume=\(shouldResume)")
                if shouldResume, self.current != nil {
                    try? AVAudioSession.sharedInstance().setActive(true, options: [])
                    self.player.play()
                    self.objectWillChange.send()  // 触发 UI 更新 isPlaying
                }
            @unknown default: break
            }
        })

        observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                            object: nil,
                                            queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
            self.handlePlaybackFailure()
        })

        observers.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                            object: nil,
                                            queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
            // 卡顿不是失败：AVPlayer 会自己缓冲恢复，但网络慢时可能卡很久。
            // 先立即尝试一次 play()（有时 stall 后 rate=0 但 play() 能把它拉回来），
            // 8 秒没恢复 → 用缓存 URL 重新 attach 一次（给 AVPlayer 重新拉流的信号）。
            Log.info("播放", "缓冲卡顿（\(self.assetHost(of: item) ?? "?")），先尝试 play()，8 秒没恢复就重 attach")
            self.isBuffering = true
            if self.isPlaying { self.player.play() }
            self.stallRecoveryTimer?.invalidate()
            self.stalledSongID = self.current?.id
            self.stallRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                nonisolated(unsafe) let captured = self
                Task { @MainActor in
                    captured?.recoverFromStall()
                }
            }
        })

        observers.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry,
                                            object: nil,
                                            queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
            if let log = item.errorLog(), let event = log.events.first {
                Log.error("播放", "播放器错误日志: code=\(event.errorStatusCode) \(event.uri ?? "")")
            }
        })
    }

    private func assetHost(of item: AVPlayerItem) -> String? {
        (item.asset as? AVURLAsset)?.url.host?.lowercased()
    }

    /// stall 自动恢复：优先用缓存的 URL 重新 attach 一次，
    /// 没有缓存就重新 prepare（可能换源）。attach 后强制 player.play() 确保重新启动。
    private func recoverFromStall() {
        stallRecoveryTimer?.invalidate()
        stallRecoveryTimer = nil
        guard stalledSongID == current?.id else { return }
        // 如果 AVPlayer 已经自己恢复了播放（rate > 0），直接跳过
        guard player.rate == 0 else {
            Log.info("播放", "stall 恢复定时器触发，但 rate 已经 > 0，跳过")
            return
        }
        let wasPlaying = isPlaying || player.rate > 0
        if let cached = resolvedURLCache[current!.id] {
            Log.info("播放", "stall 8 秒未恢复，用缓存 URL 重新 attach")
            attach(url: cached.url, thirdParty: cached.thirdParty, autoplay: wasPlaying)
        } else {
            Log.info("播放", "stall 8 秒未恢复，无缓存 URL，重新 prepare")
            prepare(autoplay: true)
            return
        }
        // attach 完成后 AVPlayer 可能还在等缓冲，显式 play() 再拉一次
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if self.isPlaying {
                self.player.play()
                Log.info("播放", "stall 恢复后显式 player.play()")
            }
        }
    }

    /// 播放失败：如果是第三方地址，把该域名拉黑并换源重试一次。
    /// 同一首歌最多自动重试 1 次，再多就会把音源打熔断，殃及后面所有歌。
    private func handlePlaybackFailure() {
        guard current != nil else { return }
        guard itemThirdParty,
              let asset = player.currentItem?.asset as? AVURLAsset,
              let host = asset.url.host?.lowercased() else {
            playbackError = "播放失败，换个音源试试"
            pause()
            return
        }
        Log.error("播放", "播放失败（\(host)），准备换源重试")
        if recoverySongID != current?.id {
            recoverySongID = current?.id
            recoveryAttempts = 0
        }
        guard recoveryAttempts < 1 else {
            playbackError = "这首歌暂时无法播放，去「我的 - 音源」看看"
            pause()
            return
        }
        recoveryAttempts += 1
        failedHosts.insert(host)
        if failedHosts.count > 8 { failedHosts.removeAll() }
        playbackError = "当前节点不可用，正在换源"
        prepare(autoplay: true)
    }

    private func recordHistory() {
        guard let song = current else { return }
        LibraryStore.shared.recordHistory(song)
    }

    // MARK: - 锁屏 / 控制中心

    private func updateNowPlaying() {
        guard let song = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album.isEmpty ? "Aurora Music" : song.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.toggle()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.step(1)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.step(-1)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
        // 注意：±15 秒跳转命令不能注册——锁屏的传输键位是互斥的，
        // 注册了 skip 命令 iOS 就只显示 ±15，把上一首/下一首藏起来。
        // 明确禁用，锁屏才会显示 ⏮ ⏭。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            self?.mode = event.repeatType == .one ? .single : .order
            return .success
        }
    }

    // MARK: - 播放模式

    func cycleMode() {
        mode = PlaybackMode(rawValue: (mode.rawValue + 1) % PlaybackMode.allCases.count) ?? .order
        Haptics.light()
    }
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
