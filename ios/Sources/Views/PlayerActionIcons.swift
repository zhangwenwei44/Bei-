import SwiftUI

// MARK: - 播放页动作行图标集（自绘，风格统一）

/// 播放页动作行的动作。
/// 全部自绘：同一 24×24 画布、同一线宽、同一圆头圆角 —— 视觉重量一致。
///
/// 🔴 v2.5.45 全套重新设计：统一线宽 2.0、统一圆角；
/// 动作行：喜欢 / 下载 / 音质（均衡器）/ 歌词（六边形+词）/ 更多。
enum PlayerActionGlyph {
    case favorite   // 喜欢（心形；激活时填充红）
    case download   // 下载（向下箭头 + 底部托盘）
    case quality    // 音质（卡片内均衡器竖条）
    case lyric      // 歌词（六边形 + 「词」）
    case translate  // 翻译（「文」字骨架）
    case more       // 更多（三个实心圆点，竖排）
    case downloaded // 已下载（下载托盘 + 对勾；与 .download 同线宽同坐标）
}

/// 统一规格的动作图标：24×24 画布坐标 → 实际 size，线宽随 size 等比缩放。
struct PlayerActionIcon: View {
    let glyph: PlayerActionGlyph
    /// 激活态（目前只有收藏用到：空心 → 实心填充）
    var active: Bool = false
    var tint: Color = .white
    var size: CGFloat = 22

    /// 线宽 2.0/24 —— 小尺寸下更清晰，视觉重量接近系统图标
    private var lineWidth: CGFloat { size / 24 * 2.0 }

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
                DownloadGlyph().stroke(tint, style: stroke)
            case .quality:
                QualityGlyph().stroke(tint, style: stroke)
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

/// 心形（v2.5.45：重新设计，对称饱满，双瓣圆润、底尖利落）
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

/// 下载（v2.5.45：向下箭头 + 底部 U 形托盘，重心更稳）
private struct DownloadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 箭杆
        p.move(to: b.p(12, 3.4))
        p.addLine(to: b.p(12, 13.6))
        // 箭头左翼 → 顶点 → 右翼
        p.move(to: b.p(7.2, 9.0))
        p.addLine(to: b.p(12, 13.8))
        p.addLine(to: b.p(16.8, 9.0))
        // 托盘（U 形）
        p.move(to: b.p(4.6, 16.0))
        p.addLine(to: b.p(4.6, 19.6))
        p.addLine(to: b.p(19.4, 19.6))
        p.addLine(to: b.p(19.4, 16.0))
        return p
    }
}

/// 音质（v2.5.45：卡片 + 内部均衡器三竖条，辨识度高）
private struct QualityGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 卡片外框（圆角矩形）
        let x0 = b.x(3.6), y0 = b.y(4.6), x1 = b.x(20.4), y1 = b.y(19.4)
        let r = (x1 - x0) * 0.16
        p.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                         cornerSize: CGSize(width: r, height: r))
        // 均衡器三竖条（居中，高度错落）
        p.move(to: b.p(8.2, 10.4));  p.addLine(to: b.p(8.2, 15.2))
        p.move(to: b.p(12.0, 7.8));  p.addLine(to: b.p(12.0, 16.4))
        p.move(to: b.p(15.8, 9.4));  p.addLine(to: b.p(15.8, 14.2))
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

/// 已下载：**保留「下载」的 U 形托盘**，把上方的箭头换成对勾 ——
/// 一眼认得出"这是下载这件事完成了"，而不是一个孤零零的对勾。
/// 托盘坐标与 DownloadGlyph 完全一致，线宽也一致，视觉重量对齐。
private struct DownloadedGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 对勾
        p.move(to: b.p(8.0, 11.0))
        p.addLine(to: b.p(11.2, 14.2))
        p.addLine(to: b.p(16.4, 6.6))
        // 托盘（U 形，与 DownloadGlyph 同坐标）
        p.move(to: b.p(4.6, 16.0))
        p.addLine(to: b.p(4.6, 19.6))
        p.addLine(to: b.p(19.4, 19.6))
        p.addLine(to: b.p(19.4, 16.0))
        return p
    }
}
