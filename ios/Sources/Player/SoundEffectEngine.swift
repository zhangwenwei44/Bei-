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
///
/// 🔴 v2.9.23 重写 **格式兼容**：原来 `process` 里有 `guard ... isFloat else { return }`，
/// 而 iOS 上 AAC/MP3 经 MTAudioProcessingTap 交付的往往是 **16-bit 整型 LPCM**（不是 Float32），
/// 于是 `isFloat == false` → 每个预设的处理都提前 return → **切任何音效都听不到变化**。
/// 现在不依赖浮点交付：先按交付格式把样本读成 Float，在 Float 域做三频段处理，再按原格式量化写回，
/// 整型 / 浮点 / 交错 / 非交错一律正确处理。
private final class SoundEffectProcessor {
    let preset: SoundEffectPreset
    private let bg: Float
    private let mg: Float
    private let tg: Float
    private let master: Float
    private var lpA: Float = 0   // 低通系数
    private var hpA: Float = 0   // 高通系数
    /// 每声道状态：[低通y, 高通y, 高通x1]
    private var st: [[Float]] = [[]]
    // 交付格式（prepare 里探明，process 据此读写；兼容整型/浮点、交错/非交错）
    private var fmtIsFloat = true
    private var fmtIsSigned = true
    private var fmtBitDepth = 32

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
        fmtIsFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        fmtIsSigned = (description.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        fmtBitDepth = Int(description.mBitsPerChannel)
    }

    // MARK: - 三频段处理（Float 域）

    /// 单样本三频段 tone control + 总增益 + 软裁剪（内部统一在 Float 域计算）。
    private func processSample(_ s: inout Float, channel c: Int) {
        var lpY = st[c][0], hpY = st[c][1], hpX1 = st[c][2]
        lpY += lpA * (s - lpY)
        let hp = hpA * (s - hpX1 + hpY)
        hpY = hp
        hpX1 = s
        let mid = s - lpY - hpY
        var out = (lpY * bg + mid * mg + hpY * tg) * master
        // 软裁剪，防止增益叠加爆音
        if out > 1 { out = 1 } else if out < -1 { out = -1 }
        out = Float(tanh(Double(out)))
        st[c][0] = lpY; st[c][1] = hpY; st[c][2] = hpX1
        s = out
    }

    // MARK: - 格式无关的读写

    /// 把一个声道的样本读成 [Float]（兼容整型/浮点、交错/非交错）。
    private func readChannel(_ raw: UnsafeMutableRawPointer, n: Int, channel c: Int, totalCh: Int, interleaved: Bool) -> [Float] {
        let stride = interleaved ? totalCh : 1
        let base = interleaved ? c : 0
        var out = [Float](repeating: 0, count: n)
        if fmtIsFloat {
            if fmtBitDepth == 64 {
                let p = raw.bindMemory(to: Double.self, capacity: n * stride)
                for i in 0..<n { out[i] = Float(p[i * stride + base]) }
            } else {
                let p = raw.bindMemory(to: Float32.self, capacity: n * stride)
                for i in 0..<n { out[i] = p[i * stride + base] }
            }
        } else if fmtBitDepth == 16 {
            let denom = fmtIsSigned ? (Float(Int16.max) + 1) : 32768.0
            let p = raw.bindMemory(to: Int16.self, capacity: n * stride)
            for i in 0..<n {
                let v = p[i * stride + base]
                out[i] = fmtIsSigned ? Float(v) / denom : (Float(v) - 32768) / 32768.0
            }
        } else if fmtBitDepth == 32 {
            let denom = fmtIsSigned ? (Float(Int32.max) + 1) : 2147483648.0
            let p = raw.bindMemory(to: Int32.self, capacity: n * stride)
            for i in 0..<n {
                let v = p[i * stride + base]
                out[i] = fmtIsSigned ? Float(v) / denom : (Float(v) - 2147483648) / 2147483648.0
            }
        } else if fmtBitDepth == 8 {
            let p = raw.bindMemory(to: Int8.self, capacity: n * stride)
            for i in 0..<n {
                let v = p[i * stride + base]
                out[i] = fmtIsSigned ? Float(v) / 128.0 : (Float(v) - 128) / 128.0
            }
        }
        return out
    }

    /// 把处理后的 [Float] 写回原缓冲区（按交付格式量化回去）。
    private func writeChannel(_ raw: UnsafeMutableRawPointer, values: [Float], channel c: Int, totalCh: Int, interleaved: Bool) {
        let n = values.count
        let stride = interleaved ? totalCh : 1
        let base = interleaved ? c : 0
        if fmtIsFloat {
            if fmtBitDepth == 64 {
                let p = raw.bindMemory(to: Double.self, capacity: n * stride)
                for i in 0..<n { p[i * stride + base] = Double(values[i]) }
            } else {
                let p = raw.bindMemory(to: Float32.self, capacity: n * stride)
                for i in 0..<n { p[i * stride + base] = values[i] }
            }
        } else if fmtBitDepth == 16 {
            let p = raw.bindMemory(to: Int16.self, capacity: n * stride)
            for i in 0..<n {
                var v = Int(values[i] * 32768)
                if v < -32768 { v = -32768 } else if v > 32767 { v = 32767 }
                p[i * stride + base] = Int16(v)
            }
        } else if fmtBitDepth == 32 {
            let p = raw.bindMemory(to: Int32.self, capacity: n * stride)
            for i in 0..<n {
                var v = Int(values[i] * 2147483648)
                if v < -2147483648 { v = -2147483648 } else if v > 2147483647 { v = 2147483647 }
                p[i * stride + base] = Int32(v)
            }
        } else if fmtBitDepth == 8 {
            let p = raw.bindMemory(to: Int8.self, capacity: n * stride)
            for i in 0..<n {
                var v = Int(values[i] * 128)
                if v < -128 { v = -128 } else if v > 127 { v = 127 }
                p[i * stride + base] = Int8(v)
            }
        }
    }

    /// 在音频 buffer 上做三频段处理：兼容任意 LPCM 交付格式（整型/浮点、交错/非交错）。
    func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard preset != .off else { return }
        let n = Int(frames)
        guard n > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        // 交错：单 buffer 且声道数 > 1；非交错：每声道一个 buffer。
        let interleaved = (buffers.count == 1 && buffers[0].mNumberChannels > 1)
        let totalCh = interleaved ? Int(buffers[0].mNumberChannels) : buffers.count
        guard totalCh > 0 else { return }
        if st.count != totalCh { st = (0..<totalCh).map { _ in [Float](repeating: 0, count: 3) } }

        if interleaved {
            guard let raw = buffers[0].mData else { return }
            for c in 0..<totalCh {
                var ch = readChannel(raw, n: n, channel: c, totalCh: totalCh, interleaved: true)
                for i in 0..<n { processSample(&ch[i], channel: c) }
                writeChannel(raw, values: ch, channel: c, totalCh: totalCh, interleaved: true)
            }
        } else {
            for c in 0..<totalCh {
                guard let raw = buffers[c].mData else { continue }
                var ch = readChannel(raw, n: n, channel: 0, totalCh: 1, interleaved: false)
                for i in 0..<n { processSample(&ch[i], channel: c) }
                writeChannel(raw, values: ch, channel: 0, totalCh: 1, interleaved: false)
            }
        }
    }
}

// MARK: - 构建 AVAudioMix（挂到 AVPlayerItem）

/// 🔴 用 MTAudioProcessingTap 把上面的 DSP 接到 AVPlayer 的音频渲染链上。
/// 默认 off 返回 nil（不挂），正常播放零影响；仅选了预设才构建。
enum SoundEffectEngine {
    static func audioMix(for preset: SoundEffectPreset) -> AVAudioMix? {
        guard preset != .off else { return nil }
        let proc = SoundEffectProcessor(preset: preset)

        // 把 processor 的 retained 指针放进 clientInfo 字段，
        // 并在 init 回调里转存到 tap storage，供 prepare/process/finalize 取回。
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(proc).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<SoundEffectProcessor>.fromOpaque(storage).release()
            },
            prepare: { tap, _, asbd in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<SoundEffectProcessor>.fromOpaque(storage)
                    .takeUnretainedValue()
                    .prepare(description: asbd.pointee)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, flags, bufferList, framesOut, flagsOut in
                var f = flags
                var gotFrames = numberFrames
                var tr = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferList, &f, &tr, &gotFrames)
                if status == noErr {
                    let storage = MTAudioProcessingTapGetStorage(tap)
                    Unmanaged<SoundEffectProcessor>.fromOpaque(storage)
                        .takeUnretainedValue()
                        .process(bufferList, frames: gotFrames)
                }
                framesOut.pointee = gotFrames
                flagsOut.pointee = f
            }
        )

        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, MTAudioProcessingTapCreationFlags(1), &tap)
        guard status == noErr, let t = tap?.takeRetainedValue() else { return nil }
        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = t
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
