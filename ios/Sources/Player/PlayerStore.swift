import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 播放核心：队列、在线地址解析、歌词、锁屏控制、历史。
final class PlayerStore: ObservableObject {
    // MARK: 队列

    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = -1
    @Published var mode: PlaybackMode = .order

    // MARK: 播放状态

    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var playbackError: String?
    @Published private(set) var sourceName: String = ""
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var bufferedFraction: Double = 0
    @Published private(set) var bitrateLabel: String = ""

    // MARK: 歌词与视觉

    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var currentLyricIndex: Int?
    @Published private(set) var artwork: UIImage?
    /// 当前歌手的写真，播放页背景用。拿不到时界面自己兜底。
    @Published private(set) var artistPhoto: UIImage?
    @Published private(set) var currentPalette = ArtworkPaletteEngine.palette(for: nil, seed: "-")
    @Published var showTranslation = false

    // MARK: 交互

    @Published private(set) var isLiked = false
    @Published var isQueuePresented = false
    /// 睡眠定时结束时间，nil 表示未设置。
    @Published var sleepTimerEnd: Date?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var shuffleHistory: [Int] = []
    private var failedHosts = Set<String>()
    private var preparingTask: Task<Void, Never>?
    private var artworkTaskID: String?
    private var artistPhotoTaskID: String?
    private var lyricTaskID: String?
    private var lastNowPlayingSecond = -1

    var current: Song? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }
    var sleepTimerRemaining: TimeInterval? {
        guard let sleepTimerEnd else { return nil }
        return max(0, sleepTimerEnd.timeIntervalSinceNow)
    }

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        installTimeObserver()
        installNotifications()
        installRemoteCommands()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        currentIndex = -1
        isPlaying = false
        isLoading = false
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
        artistPhoto = nil
        refreshArtwork(for: song)
        loadArtistPhoto(for: song)
        loadLyrics(for: song)

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
            await MainActor.run { [weak self] in
                guard let self, self.current?.id == song.id else { return }
                self.isLoading = false
                self.sourceName = outcome.name
                self.bitrateLabel = outcome.label
                guard let url = outcome.url else {
                    self.playbackError = "这首歌暂时无法播放，去「我的 - 音源」看看"
                    self.player.pause()
                    self.isPlaying = false
                    return
                }
                self.attach(url: url, thirdParty: outcome.isThirdParty, autoplay: autoplay)
            }
        }
        preparingTask = task
    }

    private func attach(url: URL, thirdParty: Bool, autoplay: Bool) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemThirdParty = thirdParty
        // 这次能播，之前拉黑的节点就放回候选池
        failedHosts = []
        if autoplay {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        updateNowPlaying()
    }

    private var itemThirdParty = false

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
            let parsed = LRCParser.parse(lrc)
            guard !parsed.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lyricTaskID == song.id else { return }
                self.lyrics = parsed
                self.refreshLyric()
            }
        }
    }

    private func refreshLyric() {
        let found = LRCParser.index(at: currentTime, in: lyrics)
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
        let placeholder = ArtworkPaletteEngine.palette(for: nil, seed: seed)
        if let current = artwork {
            currentPalette = ArtworkPaletteEngine.palette(for: current, seed: seed)
            return
        }
        currentPalette = placeholder
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
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
            if let item = self.player.currentItem {
                let total = item.duration.seconds
                if total.isFinite, total > 0 { self.duration = total }
                let range = item.loadedTimeRanges.first?.timeRangeValue
                let buffer = range.map { Double($0.duration.seconds / total) } ?? 0
                self.bufferedFraction = buffer.isFinite ? max(0, min(1, buffer)) : 0
            }
            self.refreshLyric()

            if let end = self.sleepTimerEnd, Date() >= end {
                self.sleepTimerEnd = nil
                self.pause()
            }
            // 每秒刷新一次锁屏信息即可
            if Int(self.currentTime) != self.lastNowPlayingSecond {
                self.lastNowPlayingSecond = Int(self.currentTime)
                self.updateNowPlaying()
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
            self.handlePlaybackFailure()
        })
    }

    /// 播放失败：如果是第三方地址，把该域名拉黑并换源重试一次。
    private func handlePlaybackFailure() {
        guard current != nil else { return }
        guard itemThirdParty,
              let asset = player.currentItem?.asset as? AVURLAsset,
              let host = asset.url.host?.lowercased() else {
            playbackError = "播放失败，换个音源试试"
            pause()
            return
        }
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
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 15)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15)
            return .success
        }
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
