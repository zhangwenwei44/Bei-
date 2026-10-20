import SwiftUI

// MARK: - 播放页动作行图标集（自绘，风格统一）

/// 播放页动作行的四个动作。
/// 之前混用 SF Symbol（heart / arrow.down.to.line / waveform / text.quote），
/// 四个符号的线宽、留白、重心各不相同，凑在一行里显得杂乱。
/// 这里全部自绘：同一 24×24 画布、同一线宽、同一圆头圆角 —— 视觉重量一致。
enum PlayerActionGlyph {
    case favorite   // 喜欢（心形；激活时填充红）
    case download   // 下载（向下箭头 + 底部托盘横线）
    case quality    // 音质（波形竖条）
    case lyric      // 歌词（三行文本，中间行为当前句）
    case translate  // 翻译（「文」字骨架）
    case comment    // 评论（圆角气泡 + 尾巴）
    case more       // 更多（三个实心圆点）
}

/// 统一规格的动作图标：24×24 画布坐标 → 实际 size，线宽随 size 等比缩放。
struct PlayerActionIcon: View {
    let glyph: PlayerActionGlyph
    /// 激活态（目前只有收藏用到：空心 → 实心填充）
    var active: Bool = false
    var tint: Color = .white
    var size: CGFloat = 22

    private var lineWidth: CGFloat { size / 24 * 1.7 }

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
                WaveformGlyph().stroke(tint, style: stroke)
            case .lyric:
                LyricGlyph().stroke(tint, style: stroke)
            case .translate:
                TranslateGlyph().stroke(tint, style: stroke)
            case .comment:
                CommentGlyph().stroke(tint, style: stroke)
            case .more:
                MoreGlyph().fill(tint)
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

/// 心形（左右对称，顶凹 9.6、底尖 20.6）
private struct HeartGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(12, 20.6))
        // 左半：底尖 → 左腰 → 左瓣顶 → 顶凹
        p.addCurve(to: b.p(3.8, 12.9), control1: b.p(8.4, 17.8), control2: b.p(4.6, 15.4))
        p.addCurve(to: b.p(8.1, 5.9),  control1: b.p(3.8, 10.8), control2: b.p(5.2, 7.7))
        p.addCurve(to: b.p(12, 9.6),   control1: b.p(10.6, 5.9), control2: b.p(12, 7.0))
        // 右半：顶凹 → 右瓣顶 → 右腰 → 底尖
        p.addCurve(to: b.p(15.9, 5.9), control1: b.p(12, 7.0),   control2: b.p(13.4, 5.9))
        p.addCurve(to: b.p(20.2, 12.9),control1: b.p(18.8, 7.7), control2: b.p(20.2, 10.8))
        p.addCurve(to: b.p(12, 20.6),  control1: b.p(19.8, 15.4),control2: b.p(15.6, 17.8))
        p.closeSubpath()
        return p
    }
}

/// 下载：竖直箭杆 + V 形箭头 + 底部托盘横线
private struct DownloadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(12, 4.6));   p.addLine(to: b.p(12, 14.2))     // 箭杆
        p.move(to: b.p(8.1, 10.6))                                    // 箭头左翼
        p.addLine(to: b.p(12, 14.6))
        p.addLine(to: b.p(15.9, 10.6))                                // 箭头右翼
        p.move(to: b.p(5.4, 18.6)); p.addLine(to: b.p(18.6, 18.6))    // 托盘
        return p
    }
}

/// 音质：5 根波形竖条（居中，高度错落）
private struct WaveformGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        // (x, 半高)
        let bars: [(CGFloat, CGFloat)] = [(4.9, 4.0), (8.5, 7.5), (12.1, 5.0), (15.7, 8.0), (19.3, 4.5)]
        var p = Path()
        for (bx, half) in bars {
            p.move(to: b.p(bx, 12 - half))
            p.addLine(to: b.p(bx, 12 + half))
        }
        return p
    }
}

/// 歌词：三行文本线，中间最长（当前句），上下两句更短
private struct LyricGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(5.2, 7.2));  p.addLine(to: b.p(13.4, 7.2))
        p.move(to: b.p(5.2, 12.0)); p.addLine(to: b.p(18.8, 12.0))
        p.move(to: b.p(5.2, 16.8)); p.addLine(to: b.p(11.2, 16.8))
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
        let r = 1.7 * rect.width / 24           // 半径取与线宽同量级，视觉重量一致
        var p = Path()
        for vy in [5.4, 12.0, 18.6] {
            p.addEllipse(in: CGRect(x: b.x(12) - r, y: b.y(vy) - r,
                                    width: r * 2, height: r * 2))
        }
        return p
    }
}

/// 评论：圆角气泡 + 左下尾巴
private struct CommentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 气泡主体（圆角矩形，手写以便与其它字形同样走 stroke）
        let x0 = b.x(3.8), x1 = b.x(20.2), y0 = b.y(4.6), y1 = b.y(15.4)
        let r = (x1 - x0) * 0.16
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r)
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
        // 尾巴
        p.move(to: b.p(8.6, 15.3))
        p.addLine(to: b.p(8.6, 19.4))
        p.addLine(to: b.p(13.2, 15.3))
        return p
    }
}
