import SwiftUI

// MARK: - 播放页动作行图标集（自绘，风格统一）

/// 播放页动作行的动作。
/// 全部自绘：同一 24×24 画布、同一线宽、同一圆头圆角 —— 视觉重量一致。
///
/// 🔴 v2.9.12：整体重做。原版字形只占了画布 35%~75%，渲染出来比酷狗小一大圈，
/// 现在所有字形都撑到画布的 ~75%~88%，与酷狗动作行图标视觉尺寸对齐。
enum PlayerActionGlyph {
    case favorite   // 喜欢（心形；激活时填充红）
    case download   // 下载（圆角方框 + 从顶边插入的箭头 + VIP 角标）
    case quality    // 音质（静噪强音：大圆环 + 两空心小圆 + 中心 N 形波形）
    case lyric      // 歌词（六边形 + 「词」）
    case translate  // 翻译（「文」字骨架）
    case more       // 更多（三个实心圆点，竖排）
    case downloaded // 已下载（同一下载方框，把箭头换成对勾）
    case soundEffect // 音效（三条竖轨 + 横向滑块手柄 + OFF 角标）
}

/// 统一规格的动作图标：24×24 画布坐标 → 实际 size，线宽随 size 等比缩放。
struct PlayerActionIcon: View {
    let glyph: PlayerActionGlyph
    /// 激活态（目前只有收藏用到：空心 → 实心填充）
    var active: Bool = false
    var tint: Color = .white
    var size: CGFloat = 22

    /// 线宽 1.8/24 —— 比原来的 2.0 略细，配合更大的字形更接近酷狗的精致感。
    private var lineWidth: CGFloat { size / 24 * 1.8 }

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            switch glyph {
            case .favorite:
                if active { HeartGlyph().fill(tint) }
                HeartGlyph().stroke(tint, style: stroke)
            case .download:
                // 方框 + 箭头 + 右下角 VIP 角标（酷狗同款）
                ZStack {
                    DownloadBox().stroke(tint, style: stroke)
                    // 🔴 v2.9.13：箭头单独用更细的线 —— 之前箭头跟外框一样粗，
                    // 把方框顶边顶得支离破碎，整坨糊成一团。
                    DownloadArrow().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth * 0.80,
                                           lineCap: .round, lineJoin: .round))
                    Text("VIP")
                        .font(.system(size: size * 0.19, weight: .heavy))
                        .italic()
                        .foregroundStyle(tint)
                        .offset(x: size * 0.18, y: size * 0.30)
                }
            case .quality:
                ZStack {
                    QualityGlyph().stroke(tint, style: stroke)
                    // 两个空心小圆用稍细的线，避免小尺寸下糊成一坨
                    QualityRings().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth * 0.78,
                                           lineCap: .round, lineJoin: .round))
                }
            case .soundEffect:
                ZStack {
                    SoundEffectGlyph().stroke(tint, style: stroke)
                    SoundEffectHandles().stroke(tint, style: stroke)
                    // 右下角「OFF」小字（纯几何线条，跟图标同一套风格，比小号字体清晰）
                    SoundEffectOffLabel().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth * 0.80,
                                           lineCap: .round, lineJoin: .round))
                }
            case .lyric:
                // 六边形外框 + 中间「词」字
                ZStack {
                    HexagonGlyph().stroke(tint, style: stroke)
                    Text("词")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(tint)
                }
            case .translate:
                TranslateGlyph().stroke(tint, style: stroke)
            case .more:
                MoreGlyph().fill(tint)
            case .downloaded:
                // 🔴 v2.9.4：之前是「实心圆底 + 白勾」，跟旁边纯线条图标完全不是一路的，
                // 看着像贴上去的另一个控件。现在改成同一套白色描边线条。
                DownloadedGlyph().stroke(tint, style: stroke)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.18), value: active)
    }
}

/// 24×24 画布坐标 → 实际 rect 的换算（所有字形共用，保证构图一致）
private struct GlyphBox {
    let rect: CGRect
    func x(_ v: CGFloat) -> CGFloat { rect.minX + v * rect.width / 24 }
    func y(_ v: CGFloat) -> CGFloat { rect.minY + v * rect.height / 24 }
    func p(_ vx: CGFloat, _ vy: CGFloat) -> CGPoint { CGPoint(x: x(vx), y: y(vy)) }
}

/// 心形（重新设计，对称饱满，双瓣圆润、底尖利落）
private struct HeartGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(12, 20.4))
        p.addCurve(to: b.p(3.0, 12.6),  control1: b.p(7.6, 18.0),  control2: b.p(3.4, 15.6))
        p.addCurve(to: b.p(7.4, 5.2),   control1: b.p(3.0, 10.4),  control2: b.p(4.6, 7.0))
        p.addCurve(to: b.p(12, 9.6),    control1: b.p(9.2, 5.2),   control2: b.p(12, 6.6))
        p.addCurve(to: b.p(16.6, 5.2),  control1: b.p(12, 6.6),    control2: b.p(14.8, 5.2))
        p.addCurve(to: b.p(21.0, 12.6), control1: b.p(19.4, 7.0),  control2: b.p(21.0, 10.4))
        p.addCurve(to: b.p(12, 20.4),   control1: b.p(20.6, 15.6), control2: b.p(16.4, 18.0))
        p.closeSubpath()
        return p
    }
}

/// 下载外框（参考图 8658「下载」同款）：**圆角方框**，顶边在箭头处留缺口，
/// 右下角让位给「VIP」角标（底边在 x=11.8 截断、右边框在 y=11.4 截断）。
private struct DownloadBox: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        let s = rect.width / 24.0
        let x0 = 3.4, x1 = 20.6, y0 = 4.2, y1 = 20.4, r = 3.2
        var p = Path()
        // 顶边左段（箭头左侧）
        p.move(to: b.p(x0 + r, y0)); p.addLine(to: b.p(9.5, y0))
        // 左上圆角 → 左边框
        p.addArc(center: b.p(x0 + r, y0 + r), radius: r * s,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: b.p(x0, y1 - r))
        // 左下圆角 → 底边（到 VIP 角标处截断）
        p.addArc(center: b.p(x0 + r, y1 - r), radius: r * s,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: b.p(11.8, y1))
        // 顶边右段（箭头右侧）+ 右上圆角 → 右边框（到 VIP 角标上方为止）
        p.move(to: b.p(14.5, y0)); p.addLine(to: b.p(x1 - r, y0))
        p.addArc(center: b.p(x1 - r, y0 + r), radius: r * s,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: b.p(x1, 11.4))
        return p
    }
}

/// 下载箭头：从框顶插入的向下箭头（**单独一条更细的线**，跟外框区分开）
private struct DownloadArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(12.0, 2.4)); p.addLine(to: b.p(12.0, 12.0))
        p.move(to: b.p(9.4, 9.4)); p.addLine(to: b.p(12.0, 12.0)); p.addLine(to: b.p(14.6, 9.4))
        return p
    }
}

/// 音质（参考图 43f7「静噪强音」同款）：
/// **大圆环 + 左上/右下两处缺口 + 缺口处各悬一个空心小圆 + 中心 N 形波形**
/// 🔴 v2.9.12 修正：① 环半径 4.6 → 8.4（原来直径不到画布一半，视觉上小一圈）；
/// ② 缺口端点由实心点改为**空心小圆**（参考图是空心）。
private struct QualityGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24.0
        let cx = rect.minX + 12 * s
        let cy = rect.minY + 12 * s
        let r = 8.4 * s
        var p = Path()
        // 圆环：左上（10 点方向）与右下（4 点方向）各留一个缺口
        let steps = 72
        var started = false
        for i in 0...steps {
            let deg = Double(i) * 360.0 / Double(steps)
            let inGap = (deg >= 208 && deg <= 238) || (deg >= 24 && deg <= 54)
            guard !inGap else { started = false; continue }
            let a = deg * .pi / 180
            let x = cx + r * CGFloat(cos(a))
            let y = cy + r * CGFloat(sin(a))
            if !started { p.move(to: CGPoint(x: x, y: y)); started = true }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        // 中心 N 形波形（低 → 峰 → 谷 → 升）
        p.move(to: CGPoint(x: cx - 3.3 * s, y: cy + 0.7 * s))
        p.addLine(to: CGPoint(x: cx + 0.1 * s, y: cy - 2.3 * s))
        p.addLine(to: CGPoint(x: cx + 2.1 * s, y: cy + 0.4 * s))
        p.addLine(to: CGPoint(x: cx + 3.6 * s, y: cy - 2.3 * s))
        return p
    }
}

/// 音质缺口处的两个**空心小圆**（参考图：断口处各悬一个小圆，像两颗旋钮）
private struct QualityRings: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24.0
        let cx = rect.minX + 12 * s
        let cy = rect.minY + 12 * s
        let r = 8.4 * s
        let rr = 1.55 * s
        var p = Path()
        // 左上（10 点方向）与右下（4 点方向）各悬一个空心小圆，都略微凸出环外
        for (deg, dist) in [(221.0, 9.9), (39.0, 9.9)] {
            let a = deg * .pi / 180
            let x = cx + dist * s * CGFloat(cos(a))
            let y = cy + dist * s * CGFloat(sin(a))
            p.addEllipse(in: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2))
        }
        return p
    }
}

/// 音效（参考图 72e4「音效」同款）：**三条竖直轨道**，每条轨道被一个横向滑块手柄断开
/// 🔴 v2.9.13：三轨压缩到左上 2/3，右下角腾出位置给「OFF」小字（跟参考图一致）。
struct SoundEffectGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // (轨道 x, 上段起, 上段止, 下段起, 下段止)
        let tracks: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (3.8,  3.2, 6.6, 9.4, 14.8),
            (7.8,  3.2, 10.4, 13.2, 14.8),
            (11.8, 3.2, 5.4, 8.2, 14.8)
        ]
        for (x, ya, yb, yc, yd) in tracks {
            p.move(to: b.p(x, ya)); p.addLine(to: b.p(x, yb))
            p.move(to: b.p(x, yc)); p.addLine(to: b.p(x, yd))
        }
        return p
    }
}

/// 音效的横向滑块手柄（三条轨道各一个，错落分布）
struct SoundEffectHandles: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // (手柄 y, 左端 x, 右端 x)
        let handles: [(CGFloat, CGFloat, CGFloat)] = [
            (8.0,  2.2, 5.4),
            (11.8, 6.2, 9.4),
            (6.8,  10.2, 13.4)
        ]
        for (y, x0, x1) in handles {
            p.move(to: b.p(x0, y)); p.addLine(to: b.p(x1, y))
        }
        return p
    }
}

/// 音效图标右下角的「OFF」小字 —— **纯几何线条**（O = 圆角框，F = 竖线+两横），
/// 不用字体渲染：小尺寸下字体是糊的，线条才认得出。
struct SoundEffectOffLabel: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        let s = rect.width / 24.0
        let y0 = 14.8, y1 = 18.8, mid = 16.8
        var p = Path()
        // O
        p.addRoundedRect(in: CGRect(x: b.x(13.2), y: b.y(y0),
                                    width: 2.2 * s, height: (y1 - y0) * s),
                         cornerSize: CGSize(width: 1.1 * s, height: 1.1 * s))
        // F
        p.move(to: b.p(16.3, y1)); p.addLine(to: b.p(16.3, y0)); p.addLine(to: b.p(18.4, y0))
        p.move(to: b.p(16.3, mid)); p.addLine(to: b.p(18.0, mid))
        // F
        p.move(to: b.p(19.1, y1)); p.addLine(to: b.p(19.1, y0)); p.addLine(to: b.p(21.2, y0))
        p.move(to: b.p(19.1, mid)); p.addLine(to: b.p(20.7, mid))
        return p
    }
}

/// 歌词图标外框：正六边形（平顶朝上）
private struct HexagonGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        let pts: [(CGFloat, CGFloat)] = [(6.0, 4.2), (18.0, 4.2), (21.2, 12.0),
                                         (18.0, 19.8), (6.0, 19.8), (2.8, 12.0)]
        p.move(to: b.p(pts[0].0, pts[0].1))
        for i in 1..<pts.count { p.addLine(to: b.p(pts[i].0, pts[i].1)) }
        p.closeSubpath()
        return p
    }
}

/// 翻译：「文」字骨架（顶部横 + 左撇 + 右捺）
private struct TranslateGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(6.0, 6.8));  p.addLine(to: b.p(18.0, 6.8))    // 横
        p.move(to: b.p(12.4, 6.6)); p.addLine(to: b.p(6.8, 18.4))    // 撇
        p.move(to: b.p(8.4, 12.4)); p.addLine(to: b.p(17.4, 18.4))   // 捺
        return p
    }
}

/// 更多：三个实心圆点（**竖排**，参考图最右侧「⋮」酷狗同款）
private struct MoreGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        let r = 1.8 * rect.width / 24
        var p = Path()
        for vy in [5.4, 12.0, 18.6] {
            p.addEllipse(in: CGRect(x: b.x(12) - r, y: b.y(vy) - r,
                                    width: r * 2, height: r * 2))
        }
        return p
    }
}

/// 已下载：**跟「下载」同一个方框**，把箭头换成对勾 ——
/// 一眼认得出"这是下载这件事完成了"，而不是一个孤零零的对勾。
/// 方框坐标与 DownloadBox 完全一致，线宽也一致，视觉重量对齐。
private struct DownloadedGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        let s = rect.width / 24.0
        let x0 = 3.4, x1 = 20.6, y0 = 4.2, y1 = 20.4, r = 3.2
        var p = Path()
        // 完整方框（无箭头 → 顶边不开口）
        p.move(to: b.p(x0 + r, y0)); p.addLine(to: b.p(x1 - r, y0))
        p.addArc(center: b.p(x1 - r, y0 + r), radius: r * s,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: b.p(x1, y1 - r))
        p.addArc(center: b.p(x1 - r, y1 - r), radius: r * s,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: b.p(x0 + r, y1))
        p.addArc(center: b.p(x0 + r, y1 - r), radius: r * s,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: b.p(x0, y0 + r))
        p.addArc(center: b.p(x0 + r, y0 + r), radius: r * s,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        // 对勾
        p.move(to: b.p(8.4, 12.8))
        p.addLine(to: b.p(11.0, 15.4))
        p.addLine(to: b.p(15.8, 9.6))
        return p
    }
}
