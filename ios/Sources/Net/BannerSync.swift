import Foundation
import UIKit

/// 横幅广告云端同步（Supabase Storage 公开桶 `banners`）。
///
/// - 读取：`GET <project>/storage/v1/object/public/banners/meta.json` + `0.png/0.jpg ...`，
///   公网直取、**所有设备（含未登录）都能拉**，无需 token。
/// - 写入：仅管理员（已登录 Aurora 云账号）用其会话 token 上传。
///
/// 🔴 v2.9.14 修复「其他设备看不到管理员设置的横幅」：
/// - 上传前把图片**压缩**（原来直接传原图，1 张就 1.4MB，弱网下别的手机下载必失败）；
/// - 读取时**保留占位**（某张图下载失败也占一个位置，数量与云端一致，不会整组退回默认图）；
/// - 读取失败与「云端确实没有横幅」区分开（失败时保留本机已有横幅，不会被清空）。
enum BannerSync {
    static let bucket = "banners"

    private static var publicBase: String {
        "\(SupabaseConfig.url)/storage/v1/object/public/\(bucket)"
    }

    /// 云端元数据：横幅名称 + 每张图的后缀（老数据没有 exts，一律按 png 读）。
    struct Meta: Codable {
        let names: [String]
        var exts: [String]?
    }

    /// 拉取云端横幅。
    /// - Returns: (images, error)。`images` 为 nil 表示**拉取失败**（调用方应保留本机已有数据）；
    ///   空数组表示**云端确实一张横幅都没有**。
    static func fetch() async -> (images: [UIImage?]?, error: String?) {
        guard SupabaseConfig.isConfigured else { return (nil, "云端未配置") }
        guard let metaURL = URL(string: "\(publicBase)/meta.json") else { return (nil, "地址错误") }

        var metaReq = URLRequest(url: metaURL)
        metaReq.timeoutInterval = 15
        metaReq.cachePolicy = .reloadIgnoringLocalCacheData
        let metaData: Data
        let metaResp: URLResponse
        do {
            (metaData, metaResp) = try await URLSession.shared.data(for: metaReq)
        } catch {
            let msg = "云端横幅读取失败：\(error.localizedDescription)"
            Log.warn("横幅", msg)
            return (nil, msg)
        }
        if let http = metaResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = "云端横幅读取失败（HTTP \(http.statusCode)）"
            Log.warn("横幅", msg)
            return (nil, msg)
        }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else {
            let msg = "云端横幅数据解析失败"
            Log.warn("横幅", msg)
            return (nil, msg)
        }

        var images: [UIImage?] = []
        for i in 0..<meta.names.count {
            let ext = (meta.exts?.indices.contains(i) == true) ? (meta.exts?[i] ?? "png") : "png"
            guard let u = URL(string: "\(publicBase)/\(i).\(ext)") else { images.append(nil); continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 30
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (d, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let img = UIImage(data: d) {
                images.append(img)
            } else {
                Log.warn("横幅", "第 \(i + 1) 张云端横幅下载失败，用默认图占位")
                images.append(nil) // 占位：数量与云端一致，不会整组退回默认图
            }
        }
        return (images, nil)
    }

    /// 上传横幅（管理员，已登录）。`banners` 为自定义图数组（nil 已过滤）。
    /// 返回 nil 表示成功，否则为可展示给用户的错误信息。
    @discardableResult
    static func upload(_ banners: [(name: String, image: UIImage)]) async -> String? {
        guard SupabaseConfig.isConfigured else { return "云端未配置（请填写 SupabaseConfig）" }
        guard let token = CloudAccount.shared.currentAccessToken else { return "请先登录 Aurora 云账号" }
        let apikey = SupabaseConfig.anonKey
        let base = "\(SupabaseConfig.url)/storage/v1/object/\(bucket)"

        var exts: [String] = []
        for (i, b) in banners.enumerated() {
            guard let (data, ext) = compress(b.image) else { return "第 \(i + 1) 张图片处理失败" }
            exts.append(ext)
            guard let u = URL(string: "\(base)/\(i).\(ext)?upsert=true") else { return "上传地址错误" }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(apikey, forHTTPHeaderField: "apikey")
            req.setValue(ext == "jpg" ? "image/jpeg" : "image/png", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            do {
                let (body, r) = try await URLSession.shared.data(for: req)
                if let http = r as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let detail = String(data: body, encoding: .utf8) ?? ""
                    return "上传第 \(i + 1) 张失败（HTTP \(http.statusCode)）\(detail.isEmpty ? "" : "：\(detail.prefix(120))")"
                }
            } catch {
                return "上传第 \(i + 1) 张失败：\(error.localizedDescription)"
            }
        }

        var meta = Meta(names: banners.map { $0.name }, exts: exts)
        if meta.exts?.count != meta.names.count { meta.exts = nil }
        guard let mData = try? JSONEncoder().encode(meta) else { return "元数据编码失败" }
        guard let mu = URL(string: "\(base)/meta.json?upsert=true") else { return "元数据地址错误" }
        var mreq = URLRequest(url: mu)
        mreq.httpMethod = "POST"
        mreq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        mreq.setValue(apikey, forHTTPHeaderField: "apikey")
        mreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mreq.httpBody = mData
        do {
            let (body, r) = try await URLSession.shared.data(for: mreq)
            if let http = r as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let detail = String(data: body, encoding: .utf8) ?? ""
                return "同步横幅清单失败（HTTP \(http.statusCode)）\(detail.isEmpty ? "" : "：\(detail.prefix(120))")"
            }
        } catch {
            return "同步横幅清单失败：\(error.localizedDescription)"
        }
        return nil
    }

    /// 上传前压缩：长边缩到 ≤1400px，JPEG(0.9) 与 PNG 取更小的那个。
    /// 🔴 原来直接传原图（1 张 1.4MB），别的手机弱网下载必失败 → 看不到横幅。
    private static func compress(_ image: UIImage) -> (Data, String)? {
        let maxSide: CGFloat = 1400
        var img = image
        let longSide = max(image.size.width, image.size.height)
        if longSide > maxSide {
            let ratio = maxSide / longSide
            let size = CGSize(width: (image.size.width * ratio).rounded(),
                              height: (image.size.height * ratio).rounded())
            let renderer = UIGraphicsImageRenderer(size: size)
            img = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        // 带透明通道的图必须用 PNG（转 JPEG 会变黑底）。
        let alphaInfo = img.cgImage?.alphaInfo
        let hasAlpha: Bool
        if let info = alphaInfo {
            hasAlpha = info != .none && info != .noneSkipFirst && info != .noneSkipLast
        } else {
            hasAlpha = false
        }
        let jpg = hasAlpha ? nil : img.jpegData(compressionQuality: 0.9)
        let png = img.pngData()
        switch (jpg, png) {
        case let (j?, p?):
            return j.count <= p.count ? (j, "jpg") : (p, "png")
        case let (j?, nil):
            return (j, "jpg")
        case let (nil, p?):
            return (p, "png")
        default:
            return nil
        }
    }
}
