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

    /// 🔴 v2.5.42 重新设计：线宽 1.7 → 2.0，小尺寸下更清晰、更接近系统图标的视觉重量
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
                WaveformGlyph().stroke(tint, style: stroke)
            case .lyric:
                // 🔴 参考图 v2.5.41：六边形外框 + 中间「词」字
                ZStack {
                    HexagonGlyph().stroke(tint, style: stroke)
                    Text("词")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(tint)
                }
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

/// 心形（v2.5.42 重新设计：更饱满的标准心形，顶凹居中、底尖居中）
private struct HeartGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 底尖 → 左腰 → 左瓣顶 → 顶凹
        p.move(to: b.p(12, 20.4))
        p.addCurve(to: b.p(3.4, 12.6), control1: b.p(8.0, 17.7), control2: b.p(4.2, 15.2))
        p.addCurve(to: b.p(7.6, 5.4),  control1: b.p(3.4, 10.4), control2: b.p(4.8, 7.2))
        p.addCurve(to: b.p(12, 9.2),   control1: b.p(9.2, 5.4),  control2: b.p(12, 6.6))
        // 顶凹 → 右瓣顶 → 右腰 → 底尖
        p.addCurve(to: b.p(16.4, 5.4), control1: b.p(12, 6.6),   control2: b.p(14.8, 5.4))
        p.addCurve(to: b.p(20.6, 12.6),control1: b.p(19.2, 7.2), control2: b.p(20.6, 10.4))
        p.addCurve(to: b.p(12, 20.4),  control1: b.p(20.2, 15.2),control2: b.p(16.0, 17.7))
        p.closeSubpath()
        return p
    }
}

/// 下载（v2.5.42 重新设计：下箭头 + 底部托盘横线，最通用的下载语义）
private struct DownloadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        p.move(to: b.p(12, 4.4))
        p.addLine(to: b.p(12, 15.0))            // 箭杆
        p.move(to: b.p(7.8, 11.0))              // 箭头左翼
        p.addLine(to: b.p(12, 15.2))
        p.addLine(to: b.p(16.2, 11.0))          // 箭头右翼
        p.move(to: b.p(5.0, 19.0))              // 托盘
        p.addLine(to: b.p(19.0, 19.0))
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

/// 歌词图标的外框：正六边形（平顶朝上，参考图同款）
private struct HexagonGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 平顶六边形：六个顶点 (6,4)(18,4)(21.4,12)(18,20)(6,20)(2.6,12)
        let pts: [(CGFloat, CGFloat)] = [(6.0, 4.2), (18.0, 4.2), (21.2, 12.0),
                                         (18.0, 19.8), (6.0, 19.8), (2.8, 12.0)]
        p.move(to: b.p(pts[0].0, pts[0].1))
        for i in 1..<pts.count { p.addLine(to: b.p(pts[i].0, pts[i].1)) }
        p.closeSubpath()
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

/// 评论（v2.5.42 重新设计：圆角气泡 + 左下尾巴 + 气泡内两行横线，上长下短）
private struct CommentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 气泡主体：(4.6,4.8) → (19.4,16.0)，圆角 4.2
        let x0 = b.x(4.6), x1 = b.x(19.4), y0 = b.y(4.8), y1 = b.y(16.0)
        let r = (x1 - x0) * 0.22
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r)
        // 底边走到尾巴起点
        p.addLine(to: CGPoint(x: x0 + 6.6, y: y1))
        // 左下尾巴（尖朝左下）
        p.addLine(to: CGPoint(x: x0 + 0.8, y: y1 + 3.6))
        p.addLine(to: CGPoint(x: x0 + 0.8, y: y1 - 0.2))
        // 回到气泡左边 → 左上角闭合
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
        // 气泡内两行横线
        p.move(to: b.p(8.4, 9.2))
        p.addLine(to: b.p(15.6, 9.2))
        p.move(to: b.p(8.4, 12.4))
        p.addLine(to: b.p(12.4, 12.4))
        return p
    }
}

/// 歌词图标的外框：正六边形（平顶朝上，参考图同款）
private struct HexagonGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 平顶六边形：六个顶点 (6,4)(18,4)(21.4,12)(18,20)(6,20)(2.6,12)
        let pts: [(CGFloat, CGFloat)] = [(6.0, 4.2), (18.0, 4.2), (21.2, 12.0),
                                         (18.0, 19.8), (6.0, 19.8), (2.8, 12.0)]
        p.move(to: b.p(pts[0].0, pts[0].1))
        for i in 1..<pts.count { p.addLine(to: b.p(pts[i].0, pts[i].1)) }
        p.closeSubpath()
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

/// 评论（参考图 v2.5.41）：圆角方气泡 + 左下小尾巴 + 气泡内两行横线（上长下短）
private struct CommentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 气泡主体：圆角矩形（4.4,4.6)→(19.6,16.2)，圆角 4
        let x0 = b.x(4.4), x1 = b.x(19.6), y0 = b.y(4.6), y1 = b.y(16.2)
        let r = (x1 - x0) * 0.22
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y0 + r), radius: r)
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r)
        p.addLine(to: CGPoint(x: x0 + 6.4, y: y1))
        // 左下尾巴：从底边靠左处折向左下角尖
        p.addLine(to: CGPoint(x: x0 + 1.2, y: y1 + 3.4))
        p.addLine(to: CGPoint(x: x0 + 1.2, y: y1 - 0.6))
        // 回到气泡左边（尾巴上沿）→ 左边框 → 左上角
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
        // 气泡内两行横线：上长下短（左对齐）
        p.move(to: b.p(8.2, 9.0))
        p.addLine(to: b.p(15.8, 9.0))
        p.move(to: b.p(8.2, 12.2))
        p.addLine(to: b.p(12.2, 12.2))
        return p
    }
}
