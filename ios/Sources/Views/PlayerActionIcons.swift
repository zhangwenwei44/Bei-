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

    /// 🔴 v2.9.18：**全动作行统一线宽** —— 之前下载 1.25、音效 1.30、歌词 1.80 各不相同，
    /// 一排看过去粗细明显不齐。现在所有自绘图标共用这一个值（24 画布里 1.5 单位）。
    private var lineWidth: CGFloat { size / 24 * 1.5 }

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
                // 外框（左「Γ」+ 右「¬」+ 底横条）+ 贯穿箭头 + 右下角斜体 VIP
                ZStack {
                    // 🔴 v2.9.22：按参考图 8658 逐像素量出的几何，
                    // 圆角改为**显式三次贝塞尔**（不再用 addArc，详见 downloadFramePath）。
                    DownloadBox().stroke(tint, style: stroke)
                    DownloadArrow().stroke(tint, style: stroke)
                    // VIP 角标位置按参考图量：底边与外框底横条大致齐平，
                    // 右缘略微穿出右边框（参考图 VIP 右缘 x=63 > 外框右缘 x=59）
                    Text("VIP")
                        .font(.system(size: size * 0.23, weight: .heavy))
                        .italic()
                        .foregroundStyle(tint)
                        .offset(x: size * 0.28, y: size * 0.20)
                }
            case .quality:
                ZStack {
                    QualityGlyph().stroke(tint, style: stroke)
                    // 两个空心小圆用稍细的线，避免小尺寸下糊成一坨
                    QualityRings().stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth * 0.85,
                                           lineCap: .round, lineJoin: .round))
                }
            case .soundEffect:
                ZStack {
                    SoundEffectGlyph().stroke(tint, style: stroke)
                    SoundEffectHandles().stroke(tint, style: stroke)
                    // 右下角状态角标：**实心粗体斜体**，字号与下载「VIP」一致。
                    // 未开音效显示 OFF，开启后显示 ON（随 SoundEffectSetting 实时刷新）。
                    let seOn = SoundEffectSetting.shared.current != .off
                    Text(seOn ? "ON" : "OFF")
                        .font(.system(size: size * 0.23, weight: .heavy))
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
                // 🔴 v2.9.26：已下载图标改成与「未下载」完全同款（同一外框 + 同一箭头），
                // 不再用对勾版本；区别只靠角标文字：未下载是「VIP」，已下载是「已下载」。
                ZStack {
                    DownloadBox().stroke(tint, style: stroke)
                    DownloadArrow().stroke(tint, style: stroke)
                    Text("已下载")
                        .font(.system(size: size * 0.19, weight: .heavy))
                        .italic()
                        .foregroundStyle(tint)
                        .offset(x: size * 0.10, y: size * 0.22)
                }
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
        p.move(to: b.p(12, 21.0))
        p.addCurve(to: b.p(2.4, 12.6),  control1: b.p(7.4, 18.4),  control2: b.p(2.8, 15.4))
        p.addCurve(to: b.p(7.2, 4.4),   control1: b.p(2.4, 10.2),  control2: b.p(4.4, 6.4))
        p.addCurve(to: b.p(12, 9.0),    control1: b.p(9.0, 4.4),   control2: b.p(12, 5.9))
        p.addCurve(to: b.p(16.8, 4.4),  control1: b.p(12, 5.9),    control2: b.p(15.0, 4.4))
        p.addCurve(to: b.p(21.6, 12.6), control1: b.p(19.6, 6.4),  control2: b.p(21.6, 10.2))
        p.addCurve(to: b.p(12, 21.0),   control1: b.p(21.2, 15.4), control2: b.p(16.6, 18.4))
        p.closeSubpath()
        return p
    }
}

/// 下载图标的共享几何：参考图 8658「下载」线稿逐像素量出，1:1 映射到 24×24 画布。
///
/// 形状 = 左「Γ」+ 右「¬」+ 中间向下箭头 + 右下角 VIP：
/// · 左竖线从顶横条一路向下，到底部左转成底横条（底横条到箭杆正下方断开）
/// · 顶横条被箭杆分成左右两段
/// · 右竖线从顶横条向下，到箭头高度附近收尾
private enum DownloadGlyph {
    static let xL: CGFloat = 2.4          // 左竖线中心
    static let xR: CGFloat = 21.7         // 右竖线中心
    static let yTop: CGFloat = 0.7        // 顶横条中心
    static let yBottom: CGFloat = 18.9    // 底横条中心
    static let r: CGFloat = 1.6           // 圆角（中心线半径）
    static let topLeftEnd: CGFloat = 7.6      // 顶横条左段右端
    static let topRightStart: CGFloat = 16.3  // 顶横条右段左端
    static let rightBottom: CGFloat = 12.5    // 右竖线下端
    static let bottomEnd: CGFloat = 12.5      // 底横条右端
    static let arrowX: CGFloat = 11.9         // 箭杆中心
    static let arrowTop: CGFloat = 0.0        // 箭杆顶端
    static let arrowTipY: CGFloat = 13.6      // 箭尖
    static let wingTopY: CGFloat = 9.0        // 箭头两翼起点高度
    static let wingLeftX: CGFloat = 8.3       // 左翼端点
    static let wingRightX: CGFloat = 15.6     // 右翼端点
}

/// 圆弧的三次贝塞尔逼近系数（90° 圆弧的标准值）。
private let downloadArcK: CGFloat = 0.5522847498

/// 画下载图标的「框」：底横条 → 左竖线 → 顶横条左段，以及顶横条右段 → 右竖线。
///
/// 🔴 v2.9.22 重写：**不再用 `Path.addArc`**。
/// SwiftUI 的 `addArc(center:radius:startAngle:endAngle:clockwise:)` 里，
/// `clockwise: true` 会把 180°→270° 扫成 **270°** 的整圈 —— 渲染出来就是
/// 用户实机截图里左上/右上角那两个巨大的圆钩。
/// 改用**显式三次贝塞尔**：起点 / 两个控制点 / 终点全部写死，方向绝对可控，
/// 且本地预览可以用同一套公式渲染，所见即所得。
private func downloadFramePath(_ b: GlyphBox) -> Path {
    let k = downloadArcK
    var p = Path()
    // ── 连续笔画：底横条右端 → 左下圆角 → 左竖线 → 左上圆角 → 顶横条左段
    p.move(to: b.p(DownloadGlyph.bottomEnd, DownloadGlyph.yBottom))
    p.addLine(to: b.p(DownloadGlyph.xL + DownloadGlyph.r, DownloadGlyph.yBottom))
    p.addCurve(to: b.p(DownloadGlyph.xL, DownloadGlyph.yBottom - DownloadGlyph.r),
               control1: b.p(DownloadGlyph.xL + DownloadGlyph.r - k * DownloadGlyph.r, DownloadGlyph.yBottom),
               control2: b.p(DownloadGlyph.xL, DownloadGlyph.yBottom - DownloadGlyph.r + k * DownloadGlyph.r))
    p.addLine(to: b.p(DownloadGlyph.xL, DownloadGlyph.yTop + DownloadGlyph.r))
    p.addCurve(to: b.p(DownloadGlyph.xL + DownloadGlyph.r, DownloadGlyph.yTop),
               control1: b.p(DownloadGlyph.xL, DownloadGlyph.yTop + DownloadGlyph.r - k * DownloadGlyph.r),
               control2: b.p(DownloadGlyph.xL + DownloadGlyph.r - k * DownloadGlyph.r, DownloadGlyph.yTop))
    p.addLine(to: b.p(DownloadGlyph.topLeftEnd, DownloadGlyph.yTop))
    // ── 顶横条右段 → 右上圆角 → 右竖线（下端止于箭尖高度）
    p.move(to: b.p(DownloadGlyph.topRightStart, DownloadGlyph.yTop))
    p.addLine(to: b.p(DownloadGlyph.xR - DownloadGlyph.r, DownloadGlyph.yTop))
    p.addCurve(to: b.p(DownloadGlyph.xR, DownloadGlyph.yTop + DownloadGlyph.r),
               control1: b.p(DownloadGlyph.xR - DownloadGlyph.r + k * DownloadGlyph.r, DownloadGlyph.yTop),
               control2: b.p(DownloadGlyph.xR, DownloadGlyph.yTop + DownloadGlyph.r - k * DownloadGlyph.r))
    p.addLine(to: b.p(DownloadGlyph.xR, DownloadGlyph.rightBottom))
    return p
}

/// 下载外框（参考图 8658「下载」同款）：
/// 左「Γ」+ 右「¬」+ 底横条，与箭杆和 VIP 角标叠在一起。
private struct DownloadBox: Shape {
    func path(in rect: CGRect) -> Path {
        downloadFramePath(GlyphBox(rect: rect))
    }
}

/// 下载箭头：从画布顶端贯穿下来的向下箭头（杆居中，两翼斜边展开）。
private struct DownloadArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(DownloadGlyph.arrowX, DownloadGlyph.arrowTop))
        p.addLine(to: b.p(DownloadGlyph.arrowX, DownloadGlyph.arrowTipY))
        p.move(to: b.p(DownloadGlyph.wingLeftX, DownloadGlyph.wingTopY))
        p.addLine(to: b.p(DownloadGlyph.arrowX, DownloadGlyph.arrowTipY))
        p.addLine(to: b.p(DownloadGlyph.wingRightX, DownloadGlyph.wingTopY))
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
        let rr = 1.55 * s   // 小圆半径（环半径改用 dist 参数，此处不再需要 r）
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
        let r = 1.9 * rect.width / 24
        var p = Path()
        for vy in [4.8, 12.0, 19.2] {
            p.addEllipse(in: CGRect(x: b.x(12) - r, y: b.y(vy) - r,
                                    width: r * 2, height: r * 2))
        }
        return p
    }
}

/// 已下载：**跟「下载」同一个外框**，把箭头换成对勾 ——
/// 一眼认得出"这是下载这件事完成了"，而不是一个孤零零的对勾。
/// 外框直接复用 downloadFramePath（坐标与线宽与下载态完全一致）。
private struct DownloadedGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = downloadFramePath(b)
        // 对勾（替代箭头，位置与箭尖重合）
        p.move(to: b.p(8.0, 10.6))
        p.addLine(to: b.p(10.9, 13.6))
        p.addLine(to: b.p(16.4, 6.6))
        return p
    }
}
