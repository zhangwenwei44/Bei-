import SwiftUI

// MARK: - 播放页动作行图标集（自绘，风格统一）

/// 播放页动作行的动作。
/// 全部自绘：同一 24×24 画布、同一线宽、同一圆头圆角 —— 视觉重量一致。
///
/// 🔴 v2.5.45 全套重新设计：统一线宽 2.0、统一圆角；
/// 动作行：喜欢 / 下载 / 音质（均衡器）/ 歌词（六边形+词）/ 更多。
enum PlayerActionGlyph {
    case favorite   // 喜欢（心形；激活时填充红）
    case download   // 下载（方框 + 向下箭头）
    case quality    // 音质（声波纹：不等高竖条）
    case lyric      // 歌词（六边形 + 「词」）
    case translate  // 翻译（「文」字骨架）
    case more       // 更多（三个实心圆点，竖排）
    case downloaded // 已下载（下载方框 + 对勾；与 .download 同线宽同坐标）
    case soundEffect // 音效（三条水平滑块，参考图同款）
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
            case .soundEffect:
                ZStack {
                    SoundEffectGlyph().stroke(tint, style: stroke)
                    SoundEffectKnobs().fill(tint)
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

/// 下载（方框 + 向下箭头，参考图同款）
private struct DownloadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 方框（圆角矩形）
        let x0 = b.x(4.4), y0 = b.y(4.0), x1 = b.x(19.6), y1 = b.y(19.4)
        let r = (x1 - x0) * 0.18
        p.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                         cornerSize: CGSize(width: r, height: r))
        // 向下箭头（箭杆 + 箭头）
        p.move(to: b.p(12.0, 8.6))
        p.addLine(to: b.p(12.0, 15.4))
        p.move(to: b.p(8.4, 12.0))
        p.addLine(to: b.p(12.0, 15.6))
        p.addLine(to: b.p(15.6, 12.0))
        return p
    }
}

/// 音质（声波纹：不等高竖条，参考图「强音/波纹」同款）
private struct QualityGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 七根竖条，高度错落（中间高、两端低），呈现声波形状
        let bars: [(CGFloat, CGFloat)] = [
            (4.2, 13.0), (7.2, 9.4), (10.2, 6.6), (12.0, 4.8),
            (13.8, 6.6), (16.8, 9.4), (19.8, 13.0)
        ]
        for (x, topY) in bars {
            p.move(to: b.p(x, topY))
            p.addLine(to: b.p(x, 20.4 - topY + 3.6)) // 对称到底部，形成「音频条」
        }
        return p
    }
}

/// 音效（三条水平滑块，参考图同款：三条横线 + 三个滑块圆点）
struct SoundEffectGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 三条水平轨道
        for vy in [6.5, 12.0, 17.5] {
            p.move(to: b.p(4.0, vy))
            p.addLine(to: b.p(20.0, vy))
        }
        return p
    }
}

/// 音效滑块圆点（三个，落在不同位置，叠在轨道上方，纯填充）
struct SoundEffectKnobs: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        let r = 2.0 * rect.width / 24
        var p = Path()
        let knobs: [(CGFloat, CGFloat)] = [(14.0, 6.5), (8.5, 12.0), (16.0, 17.5)]
        for (vx, vy) in knobs {
            p.addEllipse(in: CGRect(x: b.x(vx) - r, y: b.y(vy) - r,
                                    width: r * 2, height: r * 2))
        }
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

/// 已下载：**保留「下载」的方框**，把箭头换成对勾 ——
/// 一眼认得出"这是下载这件事完成了"，而不是一个孤零零的对勾。
/// 方框坐标与 DownloadGlyph 完全一致，线宽也一致，视觉重量对齐。
private struct DownloadedGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let b = GlyphBox(rect: rect)
        var p = Path()
        // 方框（与 DownloadGlyph 同坐标）
        let x0 = b.x(4.4), y0 = b.y(4.0), x1 = b.x(19.6), y1 = b.y(19.4)
        let r = (x1 - x0) * 0.18
        p.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                         cornerSize: CGSize(width: r, height: r))
        // 对勾
        p.move(to: b.p(8.2, 11.8))
        p.addLine(to: b.p(11.2, 14.8))
        p.addLine(to: b.p(16.2, 7.8))
        return p
    }
}
