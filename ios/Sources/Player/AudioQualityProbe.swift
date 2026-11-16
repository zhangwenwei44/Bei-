import Foundation

/// 🔴 2026-11-17：音频**真实码率**探测。
///
/// 背景：第三方音源经常「请求至臻2.0、实际只给 128k 直链」。旧界面把用户选的
/// 档位（`sourceStore.quality.title`）或音源自称档位当成播放档位显示，于是出现
/// 「界面写至臻2.0、下载文件却只有 1.3MB」的假象。这个类估算音频**实际平均码率**，
/// 让界面如实反映音频本身，不再跟着标称档位虚标。
///
/// ⚠️ 不用 `AVAssetTrack.estimatedBitRate` —— iOS SDK 根本没有这个成员（编译报错）。
/// 平均码率 = 文件字节数 × 8 / 时长（秒），对 128k / 320k 这类 CBR MP3 足够准确，
/// 也足以判断「音源是不是只给了低码率」。
enum AudioQualityProbe {
    /// 本地文件平均码率（bps）。文件大小 / 时长，最准确。
    static func bitrate(fileURL: URL, duration: Double) -> Int? {
        guard duration.isFinite, duration > 0,
              let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
            return nil
        }
        let bps = Int(size.doubleValue * 8 / duration)
        return bps > 0 ? bps : nil
    }

    /// 远程 URL 平均码率（bps）。用 HEAD 取 Content-Length，配合时长估算。
    /// CDN 不给长度 / 拒绝 HEAD 时返回 nil（界面回退到标称档位）。
    /// ⚠️ 不用 Range 兜底：`data(for:)` 会把响应体整首下载进内存，CDN 忽略 Range 时
    ///    反而为了读一个长度白下载整首歌，得不偿失。
    static func bitrate(remote url: URL, duration: Double) async -> Int? {
        guard duration.isFinite, duration > 0 else { return nil }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 8
        guard let length = await contentLength(for: head) else { return nil }
        return bps(from: length, duration: duration)
    }

    private static func contentLength(for request: URLRequest) async -> Double? {
        guard let (_, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse,
              let text = http.value(forHTTPHeaderField: "Content-Length"),
              let bytes = Double(text), bytes > 0 else { return nil }
        return bytes
    }

    private static func bps(from bytes: Double, duration: Double) -> Int? {
        let value = Int(bytes * 8 / duration)
        return value > 0 ? value : nil
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
