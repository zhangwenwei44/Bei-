import Foundation
import AudioToolbox
import CoreMedia
import AVFoundation
import Combine

// MARK: - 音效预设

/// 音效预设（10 段 peaking EQ + 总增益）。
/// 全部自绘 UI 选择，默认「关闭」，选了预设才挂到 AVPlayerItem.audioMix。
/// 🔴 2026-11-19：新增 `.custom`（均衡器自定义），频段参数由 SoundEffectSetting 持久化。
enum SoundEffectPreset: String, CaseIterable, Identifiable {
    case off        // 关闭（不挂 audioMix，零影响）
    case bass       // 超重低音
    case vocal      // 清澈人声
    case surround   // 环绕立体
    case live       // 现场 Live
    case custom     // 自定义均衡器

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:        return "关闭"
        case .bass:       return "超重低音"
        case .vocal:      return "清澈人声"
        case .surround:   return "环绕立体"
        case .live:       return "现场 Live"
        case .custom:     return "自定义音效"
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
        case .custom:     return "10 段均衡器，按你的听感调节"
        }
    }

    /// 均衡器频点（Hz）。
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500,
                                           1000, 2000, 4000, 8000, 16000]

    /// 每个频点的增益（dB）。custom 的实际值来自 SoundEffectSetting。
    var bands: [Float] {
        switch self {
        case .off:        return Array(repeating: 0, count: Self.bandFrequencies.count)
        case .bass:       return [12, 10, 7, 4, 1, -1, -2, -3, -3, -4]
        case .vocal:      return [-5, -4, -2, 1, 4, 6, 6, 4, 2, 0]
        case .surround:   return [0, -1, -2, -1, 1, 3, 5, 7, 6, 4]
        case .live:       return [3, 3, 2, 1, 2, 3, 4, 4, 5, 4]
        case .custom:     return Array(repeating: 0, count: Self.bandFrequencies.count)
        }
    }

    /// 总增益（dB）。
    var master: Float {
        switch self {
        case .off: return 0
        case .bass, .vocal, .live: return 1
        case .surround, .custom: return 0
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
    private let bandsKey = "aurora.soundEffectCustomBands"
    private let masterKey = "aurora.soundEffectCustomMaster"

    /// 当前预设（@Published 保证面板即时刷新；didSet 负责持久化 + 通知播放器）
    @Published var current: SoundEffectPreset = .off {
        didSet {
            guard oldValue != current else { return }
            UserDefaults.standard.set(current.rawValue, forKey: key)
            notify()
        }
    }

    /// 自定义均衡器 10 段增益（dB）。
    @Published private(set) var customBands: [Float] = SoundEffectSetting.defaultBands {
        didSet { UserDefaults.standard.set(customBands.map { Double($0) }, forKey: bandsKey) }
    }

    /// 自定义总增益（dB）。
    @Published private(set) var customMaster: Float = 0 {
        didSet { UserDefaults.standard.set(Double(customMaster), forKey: masterKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: key) ?? SoundEffectPreset.off.rawValue
        current = SoundEffectPreset(rawValue: raw) ?? .off

        let stored = UserDefaults.standard.array(forKey: bandsKey) as? [NSNumber] ?? []
        if stored.count == SoundEffectPreset.bandFrequencies.count {
            customBands = stored.map { min(12, max(-12, $0.floatValue)) }
        }
        let storedMaster = UserDefaults.standard.object(forKey: masterKey) as? NSNumber
        if let storedMaster = storedMaster {
            customMaster = min(6, max(-6, storedMaster.floatValue))
        }
    }

    static var defaultBands: [Float] {
        Array(repeating: 0, count: SoundEffectPreset.bandFrequencies.count)
    }

    func bands(for preset: SoundEffectPreset) -> [Float] {
        preset == .custom ? customBands : preset.bands
    }

    func master(for preset: SoundEffectPreset) -> Float {
        preset == .custom ? customMaster : preset.master
    }

    /// 保存并启用自定义均衡器参数。
    func applyCustom(bands newBands: [Float], master newMaster: Float) {
        let clamped = newBands.map { min(12, max(-12, $0)) }
        let changedToCustom = current != .custom
        customBands = clamped
        customMaster = min(6, max(-6, newMaster))
        if changedToCustom {
            current = .custom          // didSet 会通知播放器
        } else {
            notify()                   // 参数变了也要重挂 tap
        }
    }

    func resetCustom() {
        customBands = Self.defaultBands
        customMaster = 0
        if current == .custom { notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: SoundEffectSetting.didChange, object: nil)
    }
}

// MARK: - 实时 DSP（10 段 peaking EQ + 总增益）

/// RBJ peaking EQ 双二阶滤波器。
private struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0

    init(gainDb: Float, frequency: Float, sampleRate: Float, q: Float = 1.4) {
        let a = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha / a
        b0 = (1 + alpha * a) / a0
        b1 = (-2 * c) / a0
        b2 = (1 - alpha * a) / a0
        a1 = (-2 * c) / a0
        a2 = (1 - alpha / a) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// 每个 tap 实例持有一份处理状态；按声道保存一组滤波器状态。
///
/// 🔴 v2.9.23 重写 **格式兼容**：iOS 上 AAC/MP3 经 MTAudioProcessingTap 交付的往往是
/// 16-bit 整型 LPCM（不是 Float32），所以先按交付格式读成 Float，在 Float 域处理，
/// 再按原格式量化写回；整型 / 浮点、交错 / 非交错一律正确处理。
private final class SoundEffectProcessor {
    private let bands: [Float]
    private let master: Float
    private var sampleRate: Float = 44100
    /// 每声道一组 10 段滤波器。
    private var filters: [[Biquad]] = []
    // 交付格式（prepare 里探明，process 据此读写；兼容整型/浮点、交错/非交错）
    private var fmtIsFloat = true
    private var fmtIsSigned = true
    private var fmtBitDepth = 32

    init(bands: [Float], master: Float) {
        self.bands = bands
        self.master = powf(10, master / 20)
    }

    private static func makeFilters(bands: [Float], sampleRate: Float) -> [Biquad] {
        let freqs = SoundEffectPreset.bandFrequencies
        return freqs.indices.map { i in
            let gain = i < bands.count ? bands[i] : 0
            return Biquad(gainDb: gain, frequency: freqs[i], sampleRate: sampleRate)
        }
    }

    func prepare(description: AudioStreamBasicDescription) {
        sampleRate = description.mSampleRate > 0 ? Float(description.mSampleRate) : 44100
        fmtIsFloat = (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        fmtIsSigned = (description.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        fmtBitDepth = Int(description.mBitsPerChannel)
    }

    // MARK: - 10 段 EQ（Float 域）

    private func processSample(_ s: inout Float, channel c: Int) {
        guard filters.indices.contains(c) else { s = 0; return }
        var out = s
        for i in filters[c].indices { out = filters[c][i].process(out) }
        out *= master
        // 软裁剪，防止多段增益叠加爆音
        if out > 1 { out = 1 } else if out < -1 { out = -1 }
        out = Float(tanh(Double(out)))
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

    /// 在音频 buffer 上做 10 段 EQ：兼容任意 LPCM 交付格式（整型/浮点、交错/非交错）。
    func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        let n = Int(frames)
        guard n > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        // 交错：单 buffer 且声道数 > 1；非交错：每声道一个 buffer。
        let interleaved = (buffers.count == 1 && buffers[0].mNumberChannels > 1)
        let totalCh = interleaved ? Int(buffers[0].mNumberChannels) : buffers.count
        guard totalCh > 0 else { return }
        if filters.count != totalCh {
            filters = (0..<totalCh).map { _ in Self.makeFilters(bands: bands, sampleRate: sampleRate) }
        }

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
        let setting = SoundEffectSetting.shared
        let proc = SoundEffectProcessor(
            bands: setting.bands(for: preset),
            master: setting.master(for: preset)
        )

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
