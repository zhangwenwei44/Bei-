import Foundation
import AudioToolbox
import CoreMedia
import AVFoundation
import Combine

// MARK: - 音效预设

/// 音效预设（三频段 tone control + 总增益）。
/// 全部自绘 UI 选择，默认「关闭」，选了预设才挂到 AVPlayerItem.audioMix。
enum SoundEffectPreset: String, CaseIterable, Identifiable {
    case off        // 关闭（不挂 audioMix，零影响）
    case bass       // 超重低音
    case vocal      // 清澈人声
    case surround   // 环绕立体
    case live       // 现场 Live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return "关闭"
        case .bass:       return "超重低音"
        case .vocal:      return "清澈人声"
        case .surround:   return "环绕立体"
        case .live:       return "现场 Live"
        }
    }

    /// 文案（面板副标题用）
    var caption: String {
        switch self {
        case .off:        return "原生音质，不做任何处理"
        case .bass:       return "增强低频，鼓点与贝斯更有力"
        case .vocal:      return "突出人声，弱化两端"
        case .surround:   return "提升空间感与高频细节"
        case .live:       return "整体增益，临场氛围更浓"
        }
    }

    /// (低音dB, 中音dB, 高音dB, 总增益dB)
    var eq: (bass: Float, mid: Float, treble: Float, master: Float) {
        switch self {
        case .off:        return (0, 0, 0, 0)
        case .bass:       return (9, 0, -1, 1)
        case .vocal:      return (-3, 4, 3, 1)
        case .surround:   return (2, 1, 5, 0)
        case .live:       return (3, 2, 4, 1)
        }
    }
}

// MARK: - 用户音效偏好（持久化）

/// 🔴 音效选择持久化：跟随 App，重启保留。
/// 非 actor 隔离：仅读写 UserDefaults，访问方确保在主线程即可。
final class SoundEffectSetting: ObservableObject {
    static let shared = SoundEffectSetting()
    static let didChange = Notification.Name("aurora.soundEffectDidChange")

    private let key = "aurora.soundEffectPreset"

    /// 当前预设（@Published 保证面板即时刷新；didSet 负责持久化 + 通知播放器）
    @Published var current: SoundEffectPreset = .off {
        didSet {
            guard oldValue != current else { return }
            UserDefaults.standard.set(current.rawValue, forKey: key)
            // 🔴 切换预设时通知播放器：重新把 audioMix 挂到当前曲目。
            NotificationCenter.default.post(name: SoundEffectSetting.didChange, object: nil)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: key) ?? SoundEffectPreset.off.rawValue
        current = SoundEffectPreset(rawValue: raw) ?? .off
    }
}

// MARK: - 实时 DSP（纯 Swift 处理 PCM 浮点采样，三频段 tone control）

/// 每个 tap 实例持有一份处理状态；按声道保存一阶 IIR 状态。
private final class SoundEffectProcessor {
    let preset: SoundEffectPreset
    private let bg: Float
    private let mg: Float
    private let tg: Float
    private let master: Float
    private var lpA: Float = 0   // 低通系数
    private var hpA: Float = 0   // 高通系数
    private var isFloat = false
    private var channelCount = 1
    /// 每声道状态：[低通y, 高通y, 高通x1]
    private var st: [[Float]] = [[]]

    init(preset: SoundEffectPreset) {
        self.preset = preset
        let e = preset.eq
        bg = SoundEffectProcessor.gain(e.bass)
        mg = SoundEffectProcessor.gain(e.mid)
        tg = SoundEffectProcessor.gain(e.treble)
        master = SoundEffectProcessor.gain(e.master)
    }

    private static func gain(_ db: Float) -> Float {
        pow(10, db / 20)
    }

    func prepare(description: AudioStreamBasicDescription) {
        let sr = description.mSampleRate
        guard sr > 0 else { return }
        let dt = 1.0 / Float(sr)
        // 低通 ~200Hz，高通 ~3500Hz
        let rcLP = 1.0 / (2 * Float.pi * 200)
        lpA = min(0.999, dt / (rcLP + dt))
        let rcHP = 1.0 / (2 * Float.pi * 3500)
        hpA = min(0.999, rcHP / (rcHP + dt))
        isFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        channelCount = max(1, Int(description.mChannelsPerFrame))
        st = (0..<channelCount).map { _ in [Float](repeating: 0, count: 3) }
    }

    /// 在已解码的音频 buffer 上原地做三频段处理（仅 Float32、单声道/非交错）。
    func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard preset != .off, isFloat else { return }
        let n = Int(frames)
        guard n > 0 else { return }
        guard let buffers = UnsafeMutableAudioBufferListPointer(abl) else { return }
        let ch = buffers.count
        if st.count != ch { st = (0..<ch).map { _ in [Float](repeating: 0, count: 3) } }
        for c in 0..<ch {
            guard let raw = buffers[c].mData else { continue }
            // 仅处理非交错单声道 buffer（AVPlayer 解码输出通常如此）；交错则跳过，安全直通。
            if buffers[c].mNumberChannels > 1 { continue }
            let data = raw.bindMemory(to: Float.self, capacity: n)
            var lpY = st[c][0], hpY = st[c][1], hpX1 = st[c][2]
            for i in 0..<n {
                let x = data[i]
                lpY += lpA * (x - lpY)
                let hp = hpA * (x - hpX1 + hpY)
                hpY = hp
                hpX1 = x
                let mid = x - lpY - hpY
                var out = (lpY * bg + mid * mg + hpY * tg) * master
                // 软裁剪，防止增益叠加爆音
                if out > 1 { out = 1 } else if out < -1 { out = -1 }
                out = Float(tanh(Double(out)))
                data[i] = out
            }
            st[c][0] = lpY; st[c][1] = hpY; st[c][2] = hpX1
        }
    }
}

// MARK: - 构建 AVAudioMix（挂到 AVPlayerItem）

/// 🔴 用 MTAudioProcessingTap 把上面的 DSP 接到 AVPlayer 的音频渲染链上。
/// 默认 off 返回 nil（不挂），正常播放零影响；仅选了预设才构建。
enum SoundEffectEngine {
    /// PostDecode 标志原始值 = 1（不依赖具体 SDK 的类型导入方式）。
    private static let postDecodeFlag = MTAudioProcessingTapCreationFlags(rawValue: 1)

    static func audioMix(for preset: SoundEffectPreset) -> AVAudioMix? {
        guard preset != .off else { return nil }
        let proc = SoundEffectProcessor(preset: preset)
        let client = Unmanaged.passRetained(proc).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { _, clientInfo in
                Unmanaged<SoundEffectProcessor>.fromOpaque(clientInfo).release()
            },
            prepare: { _, clientInfo, _, asbd in
                let p = Unmanaged<SoundEffectProcessor>.fromOpaque(clientInfo!).takeUnretainedValue()
                p.prepare(description: asbd.pointee)
            },
            unprepare: { _, _ in },
            process: { tap, clientInfo, frames, _, bufferList, framesOut, trStart, trDur in
                var flags = MTAudioProcessingTapFlags(rawValue: 0)
                var outFrames = frames
                var ts = CMTime.zero
                var td = CMTime.zero
                let err = MTAudioProcessingTapGetSourceAudio(
                    tap, frames, bufferList, &flags, &outFrames, &ts, &td)
                if err == noErr {
                    let p = Unmanaged<SoundEffectProcessor>.fromOpaque(clientInfo!).takeUnretainedValue()
                    p.process(bufferList, frames: outFrames)
                }
                framesOut.pointee = outFrames
                trStart?.pointee = ts
                trDur?.pointee = td
            }
        )

        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               postDecodeFlag, &tap)
        guard status == noErr, let t = tap?.takeRetainedValue() else { return nil }
        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = t
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
