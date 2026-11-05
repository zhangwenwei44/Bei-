// === Lucide 图标 (由 lucide_to_swift.py 从 lucide-icons 仓库生成) ===
// 源: https://github.com/lucide-icons/lucide  (house / search / list-music / settings)
// 均为 24x24 viewBox, stroke 描边, 1.5px 细线, round caps/joins,
// 经 renderTabIcon 渲染为 template UIImage 跟随 TabBar 选中色。
import SwiftUI
import UIKit

/// 统一渲染底栏图标: 24x24 画布, 1.5px 线宽, 圆头圆角, 黑色描边,
/// 之后 .renderingMode(.template) 跟随 TabBar 选中色(选中蓝/未选中灰)。
func renderTabIcon(_ draw: (CGContext, (CGFloat, CGFloat) -> CGPoint) -> Void) -> UIImage {
    let side: CGFloat = 24
    let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
    return r.image { ctx in
        let c = ctx.cgContext
        c.setFillColor(UIColor.black.cgColor)
        c.setStrokeColor(UIColor.black.cgColor)
        c.setLineWidth(1.5)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let T: (CGFloat, CGFloat) -> CGPoint = { CGPoint(x: $0, y: $1) }
        draw(c, T)
    }
}

// ---- 主页 (house) ----
struct HomeTabIcon: View {
    var body: some View { Image(uiImage: Self.icon).renderingMode(.template) }
    private static let icon = renderTabIcon { c, T in
        c.move(to: T(15.000, 21.000))
        c.addLine(to: T(15.000, 13.000))
        c.addLine(to: T(14.951, 12.691))
        c.addLine(to: T(14.809, 12.412))
        c.addLine(to: T(14.588, 12.191))
        c.addLine(to: T(14.309, 12.049))
        c.addLine(to: T(14.000, 12.000))
        c.addLine(to: T(10.000, 12.000))
        c.addLine(to: T(9.691, 12.049))
        c.addLine(to: T(9.412, 12.191))
        c.addLine(to: T(9.191, 12.412))
        c.addLine(to: T(9.049, 12.691))
        c.addLine(to: T(9.000, 13.000))
        c.addLine(to: T(9.000, 21.000))
        c.move(to: T(3.000, 10.000))
        c.addLine(to: T(3.047, 9.569))
        c.addLine(to: T(3.186, 9.158))
        c.addLine(to: T(3.410, 8.786))
        c.addLine(to: T(3.709, 8.472))
        c.addLine(to: T(10.709, 2.472))
        c.addLine(to: T(11.183, 2.174))
        c.addLine(to: T(11.720, 2.019))
        c.addLine(to: T(12.280, 2.019))
        c.addLine(to: T(12.817, 2.174))
        c.addLine(to: T(13.291, 2.472))
        c.addLine(to: T(20.291, 8.472))
        c.addLine(to: T(20.590, 8.786))
        c.addLine(to: T(20.814, 9.158))
        c.addLine(to: T(20.953, 9.569))
        c.addLine(to: T(21.000, 10.000))
        c.addLine(to: T(21.000, 19.000))
        c.addLine(to: T(20.902, 19.618))
        c.addLine(to: T(20.618, 20.176))
        c.addLine(to: T(20.176, 20.618))
        c.addLine(to: T(19.618, 20.902))
        c.addLine(to: T(19.000, 21.000))
        c.addLine(to: T(5.000, 21.000))
        c.addLine(to: T(4.382, 20.902))
        c.addLine(to: T(3.824, 20.618))
        c.addLine(to: T(3.382, 20.176))
        c.addLine(to: T(3.098, 19.618))
        c.addLine(to: T(3.000, 19.000))
        c.strokePath()
    }
}

// ---- 搜索 (search) ----
struct SearchTabIcon: View {
    var body: some View { Image(uiImage: Self.icon).renderingMode(.template) }
    private static let icon = renderTabIcon { c, T in
        c.move(to: T(21.000, 21.000))
        c.addLine(to: T(16.660, 16.660))
        c.addEllipse(in: CGRect(x: 3.000, y: 3.000, width: 16.000, height: 16.000))
        c.strokePath()
    }
}

// ---- 我的音乐 (list-music) ----
struct MyMusicTabIcon: View {
    var body: some View { Image(uiImage: Self.icon).renderingMode(.template) }
    private static let icon = renderTabIcon { c, T in
        c.move(to: T(16.000, 5.000))
        c.addLine(to: T(3.000, 5.000))
        c.move(to: T(11.000, 12.000))
        c.addLine(to: T(3.000, 12.000))
        c.move(to: T(11.000, 19.000))
        c.addLine(to: T(3.000, 19.000))
        c.move(to: T(21.000, 16.000))
        c.addLine(to: T(21.000, 5.000))
        c.addEllipse(in: CGRect(x: 15.000, y: 13.000, width: 6.000, height: 6.000))
        c.strokePath()
    }
}

// ---- 设置 (settings) ----
struct GearTabIcon: View {
    var body: some View { Image(uiImage: Self.icon).renderingMode(.template) }
    private static let icon = renderTabIcon { c, T in
        c.move(to: T(9.671, 4.136))
        c.addLine(to: T(9.867, 3.397))
        c.addLine(to: T(10.290, 2.761))
        c.addLine(to: T(10.895, 2.295))
        c.addLine(to: T(11.618, 2.049))
        c.addLine(to: T(12.383, 2.049))
        c.addLine(to: T(13.106, 2.295))
        c.addLine(to: T(13.711, 2.761))
        c.addLine(to: T(14.134, 3.397))
        c.addLine(to: T(14.330, 4.136))
        c.addLine(to: T(14.513, 4.858))
        c.addLine(to: T(14.914, 5.486))
        c.addLine(to: T(15.491, 5.957))
        c.addLine(to: T(16.188, 6.222))
        c.addLine(to: T(16.932, 6.254))
        c.addLine(to: T(17.649, 6.051))
        c.addLine(to: T(18.385, 5.853))
        c.addLine(to: T(19.146, 5.903))
        c.addLine(to: T(19.851, 6.194))
        c.addLine(to: T(20.425, 6.697))
        c.addLine(to: T(20.806, 7.357))
        c.addLine(to: T(20.955, 8.105))
        c.addLine(to: T(20.856, 8.861))
        c.addLine(to: T(20.518, 9.545))
        c.addLine(to: T(19.979, 10.084))
        c.addLine(to: T(19.445, 10.603))
        c.addLine(to: T(19.102, 11.264))
        c.addLine(to: T(18.983, 11.999))
        c.addLine(to: T(19.102, 12.735))
        c.addLine(to: T(19.445, 13.396))
        c.addLine(to: T(19.979, 13.915))
        c.addLine(to: T(20.518, 14.454))
        c.addLine(to: T(20.856, 15.138))
        c.addLine(to: T(20.955, 15.894))
        c.addLine(to: T(20.806, 16.642))
        c.addLine(to: T(20.425, 17.302))
        c.addLine(to: T(19.851, 17.805))
        c.addLine(to: T(19.146, 18.096))
        c.addLine(to: T(18.385, 18.146))
        c.addLine(to: T(17.649, 17.948))
        c.addLine(to: T(16.932, 17.745))
        c.addLine(to: T(16.188, 17.777))
        c.addLine(to: T(15.491, 18.042))
        c.addLine(to: T(14.914, 18.513))
        c.addLine(to: T(14.513, 19.141))
        c.addLine(to: T(14.330, 19.863))
        c.addLine(to: T(14.134, 20.602))
        c.addLine(to: T(13.711, 21.238))
        c.addLine(to: T(13.106, 21.704))
        c.addLine(to: T(12.383, 21.950))
        c.addLine(to: T(11.618, 21.950))
        c.addLine(to: T(10.895, 21.704))
        c.addLine(to: T(10.290, 21.238))
        c.addLine(to: T(9.867, 20.602))
        c.addLine(to: T(9.671, 19.863))
        c.addLine(to: T(9.488, 19.141))
        c.addLine(to: T(9.087, 18.512))
        c.addLine(to: T(8.509, 18.042))
        c.addLine(to: T(7.813, 17.777))
        c.addLine(to: T(7.068, 17.745))
        c.addLine(to: T(6.351, 17.948))
        c.addLine(to: T(5.615, 18.146))
        c.addLine(to: T(4.854, 18.096))
        c.addLine(to: T(4.149, 17.805))
        c.addLine(to: T(3.575, 17.302))
        c.addLine(to: T(3.194, 16.642))
        c.addLine(to: T(3.045, 15.894))
        c.addLine(to: T(3.144, 15.138))
        c.addLine(to: T(3.482, 14.454))
        c.addLine(to: T(4.021, 13.915))
        c.addLine(to: T(4.555, 13.396))
        c.addLine(to: T(4.898, 12.735))
        c.addLine(to: T(5.017, 11.999))
        c.addLine(to: T(4.898, 11.264))
        c.addLine(to: T(4.555, 10.603))
        c.addLine(to: T(4.021, 10.084))
        c.addLine(to: T(3.483, 9.545))
        c.addLine(to: T(3.146, 8.861))
        c.addLine(to: T(3.047, 8.106))
        c.addLine(to: T(3.195, 7.358))
        c.addLine(to: T(3.577, 6.698))
        c.addLine(to: T(4.149, 6.196))
        c.addLine(to: T(4.853, 5.904))
        c.addLine(to: T(5.614, 5.854))
        c.addLine(to: T(6.350, 6.051))
        c.addLine(to: T(7.067, 6.254))
        c.addLine(to: T(7.811, 6.222))
        c.addLine(to: T(8.508, 5.957))
        c.addLine(to: T(9.085, 5.486))
        c.addLine(to: T(9.486, 4.858))
        c.addLine(to: T(9.669, 4.136))
        c.addEllipse(in: CGRect(x: 9.000, y: 9.000, width: 6.000, height: 6.000))
        c.strokePath()
    }
}

