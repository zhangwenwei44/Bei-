import AVFoundation

/// 🔴 2026-11-17：音频**真实码率**探测。
///
/// 背景：第三方音源经常「请求至臻2.0、实际只给 128k 直链」。旧界面把用户选的
/// 档位（`sourceStore.quality.title`）或音源自称档位当成播放档位显示，于是出现
/// 「界面写至臻2.0、下载文件却只有 1.3MB」的假象。这个类从 AVAsset 的音频轨道
/// 读**实测码率**，让界面如实反映音频本身，不再跟着标称档位虚标。
enum AudioQualityProbe {
    /// 实测码率（bps）。网络流 / 本地文件都适用；读不到返回 nil。
    /// 用 `asset.load(.tracks)`（iOS 15+）异步取轨道，再读 `estimatedBitRate`。
    static func bitrate(of asset: AVAsset) async -> Int? {
        do {
            let tracks = try await asset.load(.tracks)
            for track in tracks where track.mediaType == .audio {
                let rate = track.estimatedBitRate
                if rate > 0 { return rate }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// 本地文件兜底估算：文件大小 × 8 / 时长（秒）。轨道读不到码率时用。
    static func bitrate(fileURL: URL, duration: Double) -> Int? {
        guard duration > 0,
              let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
            return nil
        }
        let bps = Int(size.doubleValue * 8 / duration)
        return bps > 0 ? bps : nil
    }

    /// 把实测 bps 转成如实展示文案（带「实测」，与标称档位区分）。
    /// 例：128000 → "实测 128 kbps"；320000 → "实测 320 kbps"；
    ///     950000 → "实测 950 kbps"；2400000 → "实测 2.4 Mbps"。
    static func label(bps: Int?) -> String {
        guard let bps, bps > 0 else { return "" }
        let kbps = Double(bps) / 1000.0
        if kbps >= 1000 {
            return String(format: "实测 %.1f Mbps", kbps / 1000.0)
        }
        return "实测 \(Int(kbps.rounded())) kbps"
    }
}
