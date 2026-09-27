import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

final class PlayerStore: ObservableObject {
    @Published private(set) var songs: [Song] = []
    @Published private(set) var index: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var currentLyricIndex: Int? = nil
    @Published private(set) var bufferedFraction: Double = 0
    @Published private(set) var artwork: UIImage?
    @Published private(set) var currentPalette = ArtworkPaletteEngine.palette(for: nil, seed: "-")

    @Published var mode: PlaybackMode = .order
    @Published var isLiked = false
    @Published var isFollowed = false
    @Published var isQueuePresented = false
    @Published var volume: Double = 1 {
        didSet { player.volume = Float(volume) }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    var current: Song? { songs.indices.contains(index) ? songs[index] : nil }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    init() {
        player.actionAtItemEnd = .pause
        installTimeObserver()
        installRemoteCommands()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func reload() {
        guard songs.isEmpty else { return }
        songs = DemoLibrary.songs
        load(index: 0, autoplay: false)
    }

    func add(url: URL) {
        let isAudio = ["mp3", "m4a", "aac", "wav", "caf", "aiff", "flac"].contains(url.pathExtension.lowercased())
        guard isAudio else { return }
        let asset = AVURLAsset(url: url)
        let name = url.deletingPathExtension().lastPathComponent
        let item = Song(title: name, artist: "本地音频", url: url, tags: ["本地"], isLocal: true)
        songs.append(item)
        if index == -1 { load(index: 0, autoplay: false) }
        Task {
            if let seconds = try? await asset.load(.duration) {
                await MainActor.run { self.songs[self.songs.count - 1].duration = seconds.seconds }
            }
        }
    }

    func load(index newIndex: Int, autoplay: Bool) {
        guard songs.indices.contains(newIndex) else { return }
        index = newIndex
        let song = songs[newIndex]
        lyrics = DemoLibrary.lyrics(for: song)
        currentLyricIndex = nil
        currentTime = 0
        isLiked = LikedStore.shared.contains(song)
        refreshPalette()

        guard let url = song.url else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        duration = song.duration
        updateNowPlaying()
        if autoplay { play() }
    }

    func play() {
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
        if player.currentItem == nil, let song = current { load(index: songs.firstIndex(of: song) ?? 0, autoplay: true) }
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                   toleranceBefore: .zero,
                   toleranceAfter: .zero)
        currentTime = target
        refreshLyric()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func step(_ direction: Int, automatic: Bool = false) {
        guard !songs.isEmpty else { return }
        if automatic, mode == .single {
            seek(to: 0)
            play()
            return
        }
        let count = songs.count
        if mode == .shuffle, songs.count > 1 {
            var candidate = index
            while candidate == index { candidate = Int.random(in: 0..<count) }
            load(index: candidate, autoplay: true)
            return
        }
        load(index: (index + direction + count) % count, autoplay: true)
    }

    func remove(at offsets: IndexSet) {
        for offset in offsets.sorted(by: >) where songs.indices.contains(offset) {
            if offset == index {
                pause()
                player.replaceCurrentItem(with: nil)
                index = -1
            }
            songs.remove(at: offset)
        }
        if !songs.isEmpty {
            index = min(max(index, 0), songs.count - 1)
            load(index: index, autoplay: false)
        }
    }

    func removeAll() {
        pause()
        player.replaceCurrentItem(with: nil)
        songs = []
        index = -1
        lyrics = []
        currentTime = 0
        duration = 0
    }

    func toggleLike() {
        guard let song = current else { return }
        isLiked = LikedStore.shared.toggle(song)
    }

    func cycleMode() {
        mode = PlaybackMode(rawValue: (mode.rawValue + 1) % PlaybackMode.allCases.count) ?? .order
        Haptics.light()
    }

    private func refreshPalette() {
        guard let song = current else {
            artwork = nil
            currentPalette = ArtworkPaletteEngine.palette(for: nil, seed: "-")
            return
        }
        let seed = "\(song.artist)-\(song.title)"
        if let cached = artwork {
            currentPalette = ArtworkPaletteEngine.palette(for: cached, seed: seed)
            return
        }
        let id = song.id
        let fallback = artwork
        Task { [weak self] in
            guard let self else { return }
            let image = await Self.loadArtwork(for: song)
            let next = ArtworkPaletteEngine.palette(for: image ?? fallback, seed: seed)
            await MainActor.run {
                guard let current = self.current, current.id == id else { return }
                self.artwork = image
                withAnimation(.easeInOut(duration: 0.5)) { self.currentPalette = next }
            }
        }
    }

    private static func loadArtwork(for song: Song) async -> UIImage? {
        if let url = song.artworkURL,
           let (data, _) = try? await URLSession.shared.data(from: url),
           let image = UIImage(data: data) {
            return image
        }
        guard let url = song.url else { return nil }
        let asset = AVURLAsset(url: url)
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let value = try? await item.load(.value),
                   let image = value as? UIImage {
                    return image
                }
            }
        }
        return nil
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0
            if let item = self.player.currentItem {
                let total = item.duration.seconds
                if total.isFinite, total > 0 { self.duration = total }
                let buffer = item.loadedTimeRanges.first.map {
                    let range = $0.timeRangeValue
                    return Double(range.duration.seconds / total)
                } ?? 0
                self.bufferedFraction = max(0, min(1, buffer.isFinite ? buffer : 0))
            }
            self.refreshLyric()
        }
    }

    private func refreshLyric() {
        let found = LRCParser.index(at: currentTime, in: lyrics)
        if found != currentLyricIndex { currentLyricIndex = found }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        if let song = current {
            info[MPMediaItemPropertyTitle] = song.title
            info[MPMediaItemPropertyArtist] = song.artist
            info[MPMediaItemPropertyAlbumTitle] = "Aurora Music"
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
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
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: position.positionTime)
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
            guard let state = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            self?.mode = state.repeatType == .one ? .single : .order
            return .success
        }
    }
}

final class LikedStore {
    static let shared = LikedStore()
    private let defaults = UserDefaults.standard
    private let key = "liked.song.titles"

    private init() {}

    func contains(_ song: Song) -> Bool {
        let saved = defaults.stringArray(forKey: key) ?? []
        return saved.contains("\(song.artist)-\(song.title)")
    }

    @discardableResult
    func toggle(_ song: Song) -> Bool {
        var saved = defaults.stringArray(forKey: key) ?? []
        let id = "\(song.artist)-\(song.title)"
        if let idx = saved.firstIndex(of: id) {
            saved.remove(at: idx)
            defaults.set(saved, forKey: key)
            return false
        }
        saved.append(id)
        defaults.set(saved, forKey: key)
        return true
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
