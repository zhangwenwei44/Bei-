import Foundation
import UIKit

/// 横幅广告云端同步（Supabase Storage）。
///
/// - 读取：公开桶 `banners` 的公网 URL，所有设备（含未登录）都能拉取，无需 token。
/// - 写入：仅管理员（已登录 Aurora 云账号）通过其 Supabase 会话上传。
///
/// 前置条件：Supabase 项目需存在公开的 `banners` 桶并放行读取（见 CloudAccount / 文档里的建桶 SQL）。
/// 若未配置或桶不存在，`fetch()` 返回空数组，调用方自动回退到本机自定义图 / App 内置默认图。
enum BannerSync {
    static let bucket = "banners"

    private static var publicBase: String {
        "\(SupabaseConfig.url)/storage/v1/object/public/\(bucket)"
    }

    /// 云端元数据：横幅名称列表（下标即文件名 0.png / 1.png ...）。
    struct Meta: Codable {
        let names: [String]
    }

    /// 拉取云端横幅图片。所有用户（含未登录）均可调用。失败返回空数组。
    static func fetch() async -> [UIImage] {
        guard SupabaseConfig.isConfigured else { return [] }
        guard let metaURL = URL(string: "\(publicBase)/meta.json") else { return [] }
        do {
            let (metaData, _) = try await URLSession.shared.data(from: metaURL)
            let meta = try JSONDecoder().decode(Meta.self, from: metaData)
            var imgs: [UIImage] = []
            for i in 0..<meta.names.count {
                guard let u = URL(string: "\(publicBase)/\(i).png") else { continue }
                if let (d, _) = try? await URLSession.shared.data(from: u),
                   let img = UIImage(data: d) {
                    imgs.append(img)
                }
            }
            return imgs
        } catch {
            Log.warn("横幅", "云端拉取失败：\(error.localizedDescription)")
            return []
        }
    }

    /// 上传横幅（管理员，已登录）。`banners` 为自定义图数组（nil 已过滤，只传有图的下标）。
    /// 返回错误信息；成功返回 nil。
    @discardableResult
    static func upload(_ banners: [(name: String, image: UIImage)]) async -> String? {
        guard SupabaseConfig.isConfigured else { return "云端未配置（请填写 SupabaseConfig）" }
        guard let token = CloudAccount.shared.currentAccessToken else { return "请先登录 Aurora 云账号" }
        let apikey = SupabaseConfig.anonKey
        let base = "\(SupabaseConfig.url)/storage/v1/object/\(bucket)"

        do {
            for (i, b) in banners.enumerated() {
                guard let png = b.image.pngData() else { continue }
                guard let u = URL(string: "\(base)/\(i).png?upsert=true") else { continue }
                var req = URLRequest(url: u)
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue(apikey, forHTTPHeaderField: "apikey")
                req.setValue("image/png", forHTTPHeaderField: "Content-Type")
                req.httpBody = png
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return "上传第 \(i + 1) 张失败（HTTP \(http.statusCode)）"
                }
            }
            let meta = Meta(names: banners.map { $0.name })
            guard let mData = try? JSONEncoder().encode(meta) else { return "元数据编码失败" }
            guard let mu = URL(string: "\(base)/meta.json?upsert=true") else { return "元数据地址错误" }
            var mreq = URLRequest(url: mu)
            mreq.httpMethod = "POST"
            mreq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            mreq.setValue(apikey, forHTTPHeaderField: "apikey")
            mreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            mreq.httpBody = mData
            let (_, mresp) = try await URLSession.shared.data(for: mreq)
            if let http = mresp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return "上传元数据失败（HTTP \(http.statusCode)）"
            }
            return nil
        } catch {
            return CloudAccount.localizedCloudError(error)
        }
    }
}
