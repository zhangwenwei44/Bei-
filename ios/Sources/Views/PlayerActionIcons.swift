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
                    // 🔴 v2.9.16：用户给了酷狗手绘风的新参考图（0ea11049），
                    // 造型是 **U 形托盘 + 长箭头 + 斜体 VIP**，不是闭合方框。
                    // 手绘风关键：**托盘粗、箭头细**（参考图就是这个粗细对比）
                    DownloadTray().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: size / 24 * 2.0,
                                           lineCap: .round, lineJoin: .round))
                    DownloadArrow().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: size / 24 * 1.3,
                                           lineCap: .round, lineJoin: .round))
                    Text("VIP")
                        .font(.system(size: size * 0.22, weight: .heavy))
                        .italic()
                        .foregroundStyle(tint)
                        .offset(x: size * 0.32, y: size * 0.27)
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
                    // 🔴 v2.9.15：参考图线宽只有图宽的 4.4%，整体收细一档
                    SoundEffectGlyph().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth * 0.72,
                                           lineCap: .round, lineJoin: .round))
                    SoundEffectHandles().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth * 0.72,
                                           lineCap: .round, lineJoin: .round))
                    // 右下角「OFF」角标：**实心粗体斜体**（参考图同款，不是空心线条）
                    Text("OFF")
                        .font(.system(size: size * 0.19, weight: .heavy))
                        .italic()
                        .foregroundStyle(tint)
                        .offset(x: size * 0.30, y: size * 0.20)
                }
            case .lyric:
                // 大圆角正方形外框 + 中间「词」字（参考图 6ccb467 同款）
                ZStack {
                    LyricFrameGlyph().stroke(tint, style: stroke)
                    Text("词")
                        .font(.system(size: size * 0.40, weight: .semibold))
                        .foregroundStyle(tint)
                }
            case .translate:
                TranslateGlyph().stroke(tint, style: stroke)
            case .more:
                MoreGlyph().fill(tint)
            case .downloaded:
                // 🔴 v2.9.4：之前是「实心圆底 + 白勾」，跟旁边纯线条图标完全不是一路的，
                // 看着像贴上去的另一个控件。现在改成同一套白色描边线条。
                // v2.9.16：托盘线宽跟「下载」一致（手绘风托盘是粗的）。
                DownloadedGlyph().stroke(
                    tint,
                    style: StrokeStyle(lineWidth: size / 24 * 2.0,
                                       lineCap: .round, lineJoin: .round))
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

/// 下载托盘（参考图 0ea11049「下载」同款，酷狗手绘涂鸦风）：
/// **左侧一条略带外斜的粗竖线（底角圆滑）+ 一段底边 + 右上角一个「ʔ」形小钩**
/// 🔴 v2.9.16：之前按 8658 画成「闭合方框」，用户新参考图是 U 形托盘，整体重画。
private struct DownloadTray: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 左侧竖线：顶部略靠右、向下微微外斜（手绘感），底角圆滑
        p.move(to: b.p(3.8, 1.2))
        p.addLine(to: b.p(2.4, 19.4))
        p.addQuadCurve(to: b.p(5.2, 22.2), control: b.p(2.1, 22.2))
        // 底边（向右伸出一段）
        p.addLine(to: b.p(8.6, 22.2))
        // 右上角「ʔ」形小钩：一小段竖线 + 向左勾出的弧
        p.move(to: b.p(15.0, 7.4))
        p.addLine(to: b.p(15.0, 3.4))
        p.addQuadCurve(to: b.p(12.8, 3.0), control: b.p(13.6, 1.4))
        return p
    }
}

/// 下载箭头：从画布顶部贯穿下来的向下箭头（手绘风：杆长、箭尖深、斜边展开）。
/// 🔴 v2.9.16：配合新的 U 形托盘，箭头杆移到左侧托盘里，箭尖落在托盘底部上方。
private struct DownloadArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(7.4, 0.6)); p.addLine(to: b.p(7.4, 14.2))
        p.move(to: b.p(4.6, 10.6)); p.addLine(to: b.p(7.4, 14.2)); p.addLine(to: b.p(10.4, 10.6))
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

/// 音效（参考图 72e4「音效」同款，1:1 量过像素）：
/// **三条竖直轨道（顶端齐平）**，每条被一个横向滑块手柄断开；
/// 手柄高度错落：左上 / 中下 / 右上；右轨下段很短（给右下角「OFF」让位）。
/// 🔴 v2.9.14：按参考图重排 —— 之前三轨起点错位、右轨过长，OFF 挤在角落看不清。
struct SoundEffectGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // (轨道 x, 上段起, 上段止, 下段起, 下段止)
        let tracks: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (3.6,  1.5, 7.0,  9.8, 19.5),
            (10.4, 1.5, 11.0, 13.8, 19.5),
            (17.2, 1.5, 6.6,  9.4, 11.4)
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
            (7.7,  1.3, 5.9),
            (12.2, 8.1, 12.7),
            (7.3,  14.9, 19.5)
        ]
        for (y, x0, x1) in handles {
            p.move(to: b.p(x0, y)); p.addLine(to: b.p(x1, y))
        }
        return p
    }
}

/// 歌词图标外框：**大圆角正方形**（参考图 6ccb467 同款）
/// 🔴 v2.9.16：之前是六边形，用户新参考图改成圆角方形（圆角约为边长 28%）。
private struct LyricFrameGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        let x0 = 1.6, y0 = 1.6, w = 20.8 - 1.6, r = 5.6
        p.addRoundedRect(in: CGRect(x: b.x(x0), y: b.y(y0),
                                    width: b.x(x0 + w) - b.x(x0),
                                    height: b.y(y0 + w) - b.y(y0)),
                         cornerSize: CGSize(width: b.x(r) - b.x(0), height: b.x(r) - b.x(0)))
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

/// 已下载：**跟「下载」同一个 U 形托盘**，把箭头换成对勾 ——
/// 一眼认得出"这是下载这件事完成了"，而不是一个孤零零的对勾。
/// 托盘坐标与 DownloadTray 完全一致，线宽也一致，视觉重量对齐。
private struct DownloadedGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 托盘（与 DownloadTray 同坐标）
        p.move(to: b.p(3.8, 1.2))
        p.addLine(to: b.p(2.4, 19.4))
        p.addQuadCurve(to: b.p(5.2, 22.2), control: b.p(2.1, 22.2))
        p.addLine(to: b.p(8.6, 22.2))
        // 对勾（替代箭头）
        p.move(to: b.p(4.6, 12.6))
        p.addLine(to: b.p(7.0, 15.2))
        p.addLine(to: b.p(12.0, 8.6))
        return p
    }
}
