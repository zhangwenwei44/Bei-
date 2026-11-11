import SwiftUI

// MARK: - 播放模式图标：酷狗真机截图等值线描摹（形状 1:1，2026-11-11）
//
// 来源：player-icons/trace/ 里标为「描摹矢量 · 形状 1:1」的 -trace.svg，
//       **不是** svg/ 目录里那套手绘描边版。
//   .order   → fast-forward-trace.svg  viewBox 60.66 × 60.52（两条平行箭头线）
//   .shuffle → shuffle-trace.svg      viewBox 62.04 × 54.26（交叉箭头）
//   .single  → repeat-one-trace.svg   viewBox 60.23 × 63.05（带「1」的循环箭头）
//
// 🔴 三个 viewBox 宽高各不相同：绘制时按各自比例等比缩放并居中，
//    绝不统一拉成正方形，否则形状就不是 1:1 了。
// 🔴 原 SVG 是 `fill-rule="evenodd"` 的**填充轮廓**（不是描边），
//    SwiftUI 必须用 FillStyle(eoFill: true)，否则环形内部的洞会被填实。
// 🔴 颜色交给外部 `.foregroundStyle / .foregroundColor` 决定（ForegroundStyle()），
//    这样各主题原有的高亮逻辑（激活用主色 / 未激活用白 0.85）一行都不用改。

/// 一个模式的描摹数据：原始 viewBox + 若干条闭合轮廓（坐标仍是 SVG 原始单位）。
private struct ModeTraceSpec {
    let box: CGSize
    let contours: [[CGPoint]]

    /// 所有轮廓点的实际包围盒（不是 viewBox）。三个图标的 viewBox 各不相同，
    /// 只有把「墨迹盒」对齐，视觉大小才真的一致。
    var ink: CGRect {
        guard let first = contours.first?.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for contour in contours {
            for p in contour {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

}

private enum ModeTrace {
    // MARK: 原始 SVG path（从 trace.html 的「描摹矢量 · 形状 1:1」逐字复制）
    // 只含 M / L / Z 与数字对，没有任何曲线，解析器见 contours(_:)。
    static let orderPath =
        "M44.41 2L42.59 3.58L42.44 5.08L49.72 12.33L49.91 13.08L49.22 13.58L3.16 13.58L2.12 14.33L2.06 16.08L3.91 17.05L58.41 17.04L58.66 16.33L58.19 15.58Z" +
        "M2.66 43.51L2.1 44.33L2 46.08L2.41 46.88L3.41 47.27L49.16 47.33L49.91 47.83L49.71 48.58L43.52 54.83L42.47 56.83L42.91 57.87L44.41 58.52L45.66 57.95L58.61 44.58L58.16 43.65L56.91 43.4Z"

    static let shufflePath =
        "M45.29 2L43.72 3.54L43.75 4.79L50.02 10.29L50.24 11.79L39.54 12.34L34.29 14.1L30.56 17.54L27.74 21.79L23.72 34.79L21.83 38.79L20 40.29L17.79 41.07L2.79 41.4L2.06 42.79L2.54 44.51L17.54 44.61L20.42 44.04L22.79 42.75L25.1 40.29L26.6 37.04L30.66 23.54L33.29 19.47L36.29 17.29L42.04 15.83L57.29 15.85L60.04 15.43L59.79 14.03L46.29 2.38Z" +
        "M2.54 9.52L2 11.29L2.79 12.8L17.54 12.91L20.04 13.98L22.57 16.79L23.54 17.2L24.64 16.79L25.58 15.29L25.36 14.29L22.79 11.69L19.29 9.86L17.29 9.46Z" +
        "M33.29 35.53L32.16 36.54L32.05 38.29L34.79 40.41L41.54 42.34L50.29 42.58L50.02 44.04L43.77 49.79L43.9 51.04L45.29 52.26L46.29 51.91L59.92 39.79L59.79 39.23L58.79 38.83L42.54 38.81L38.54 37.97Z"

    static let singlePath =
        "M44.27 2L42.77 3.09L42.4 4.32L47.19 9.07L47.14 10.07L46.27 10.54L9.77 10.41L6.77 10.88L4.87 11.82L3.07 13.82L2.04 17.07L2 32.32L2.5 34.07L4.77 34.42L5.63 33.57L5.71 17.07L6.27 15.11L7.02 14.56L9.77 13.86L42.52 14.06L56.52 13.62L56.46 12.82L55.27 11.65L45.02 2.22Z" +
        "M32.77 19.5L25.72 26.82L25.19 28.07L25.75 29.57L26.77 30.24L29.02 28.81L29.77 29.15L30.05 39.32L30.47 40.32L31.27 40.65L33.02 40.53L33.57 39.32L33.61 20.82L33.46 19.82Z" +
        "M55.52 28.56L54.69 30.07L54.46 46.57L53.77 48.22L52.02 49.3L4.52 49.19L3.84 49.57L3.93 50.07L16.02 61.05L17.52 60.03L17.77 58.71L16.52 56.77L13.21 53.82L13.04 53.07L13.52 52.7L51.77 52.66L54.27 51.98L57.52 48.9L58.23 45.57L58.18 29.57L57.52 28.62Z"

    /// 静态常量只在首次访问时解析一次；Swift 保证 static let 惰性且线程安全。
    static let orderSpec   = ModeTraceSpec(box: CGSize(width: 60.66, height: 60.52), contours: contours(orderPath))
    static let shuffleSpec = ModeTraceSpec(box: CGSize(width: 62.04, height: 54.26), contours: contours(shufflePath))
    static let singleSpec  = ModeTraceSpec(box: CGSize(width: 60.23, height: 63.05), contours: contours(singlePath))

    static func spec(for mode: PlaybackMode) -> ModeTraceSpec {
        switch mode {
        case .order:   return orderSpec
        case .shuffle: return shuffleSpec
        case .single:  return singleSpec
        }
    }

    /// 极简 SVG path 解析：只认 M / L / Z 与数字对（描摹结果没有曲线、没有相对坐标）。
    /// 已用 Python 独立核对：三个路径分别得到 29 / 58 / 59 个点，与描摹元数据 pts 完全一致。
    private static func contours(_ svg: String) -> [[CGPoint]] {
        var tokens: [String] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { tokens.append(buffer); buffer = "" }
        }
        for ch in svg {
            if ch == "M" || ch == "L" || ch == "Z" || ch == "z" {
                flush()
                tokens.append(String(ch))
            } else if ch.isNumber || ch == "." || ch == "-" || ch == "+" {
                buffer.append(ch)
            } else {
                flush()   // 空格 / 逗号
            }
        }
        flush()

        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "M" || t == "L" {
                guard i + 2 < tokens.count,
                      let x = Double(tokens[i + 1]),
                      let y = Double(tokens[i + 2]) else { i += 1; continue }
                if t == "M" {
                    if !current.isEmpty { result.append(current); current = [] }
                }
                current.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                i += 3
            } else if t == "Z" || t == "z" {
                if !current.isEmpty { result.append(current); current = [] }
                i += 1
            } else {
                // M 之后的连续数字对 = 隐式 L
                guard let x = Double(t), i + 1 < tokens.count,
                      let y = Double(tokens[i + 1]) else { i += 1; continue }
                current.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                i += 2
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// 🔴 2026-11-12：三个图标统一到「顺序播放」的视觉尺寸与线宽。
///
/// 之前按各自 viewBox 等比缩放，实测 size=20 时：
///   order  墨迹 18.68×18.64  等效线宽 1.18pt
///   shuffle 墨迹 18.71×16.20  等效线宽 1.10pt（明显矮一截）
///   single  墨迹 17.84×18.73  等效线宽 1.10pt（略窄）
/// 现在把每个图标的「墨迹包围盒」映射到同一个目标框（= order 原来的墨迹框），
/// order 自身的变换逐点等价、画面一点不变；另外两个只在 x/y 上做 ≤12% 的补偿，
/// 三个图标从此一样大、一样粗。形状仍是原始描摹路径，没有改成手绘描边版。
private struct PlayerModeTraceShape: Shape {
    let mode: PlaybackMode

    private struct Transform {
        let sx: CGFloat, sy: CGFloat, ox: CGFloat, oy: CGFloat
    }

    private func transform(in rect: CGRect) -> Transform? {
        let spec = ModeTrace.spec(for: mode)
        let reference = ModeTrace.orderSpec
        let ink = spec.ink
        guard rect.width > 0, rect.height > 0,
              ink.width > 0, ink.height > 0,
              reference.ink.width > 0, reference.ink.height > 0 else { return nil }
        // 顺序播放的基准缩放（与改动前完全一致：按它自己的 viewBox 等比缩放）。
        let base = min(rect.width / reference.box.width, rect.height / reference.box.height)
        let sx = reference.ink.width * base / ink.width
        let sy = reference.ink.height * base / ink.height
        return Transform(sx: sx, sy: sy,
                         ox: rect.midX - ink.midX * sx,
                         oy: rect.midY - ink.midY * sy)
    }

    /// 归一后的等效线宽（pt）：面积按 sx·sy 缩放、周长按均方根缩放。
    /// 用它而不是「路径原始单位的线宽差」来算补偿，才不会过冲。
    func normalizedStroke(in rect: CGRect) -> CGFloat {
        guard let t = transform(in: rect) else { return 0 }
        let spec = ModeTrace.spec(for: mode)
        var a: CGFloat = 0, p: CGFloat = 0
        for contour in spec.contours where contour.count >= 3 {
            var twice: CGFloat = 0
            for i in contour.indices {
                let u = contour[i], v = contour[(i + 1) % contour.count]
                twice += u.x * v.y - v.x * u.y
                p += hypot((v.x - u.x) * t.sx, (v.y - u.y) * t.sy)
            }
            a += abs(twice) / 2 * t.sx * t.sy
        }
        return p > 0 ? 2 * a / p : 0
    }

    func path(in rect: CGRect) -> Path {
        let spec = ModeTrace.spec(for: mode)
        guard let t = transform(in: rect) else { return Path() }
        func p(_ point: CGPoint) -> CGPoint {
            CGPoint(x: t.ox + point.x * t.sx, y: t.oy + point.y * t.sy)
        }
        var path = Path()
        for contour in spec.contours {
            guard let first = contour.first else { continue }
            path.move(to: p(first))
            for point in contour.dropFirst() { path.addLine(to: p(point)) }
            path.closeSubpath()
        }
        return path
    }
}

/// 三个播放模式图标的统一入口。
/// 用法与原 `Image(systemName:)` 完全一致：
///   `PlayerModeIcon(mode: store.mode, size: 20).foregroundStyle(.white)`
struct PlayerModeIcon: View {
    let mode: PlaybackMode
    var size: CGFloat = 20

    /// 归一后 single 的等效线宽仍比 order 细约 0.06pt，
    /// 叠一层等色极细描边补回来（只加粗轮廓，不改形状、不改整体尺寸）。
    private var strokeBoost: CGFloat {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let ref = PlayerModeTraceShape(mode: .order).normalizedStroke(in: rect)
        let cur = PlayerModeTraceShape(mode: mode).normalizedStroke(in: rect)
        return max(0, ref - cur)
    }

    var body: some View {
        ZStack {
            PlayerModeTraceShape(mode: mode)
                .fill(ForegroundStyle(), style: FillStyle(eoFill: true))
            if strokeBoost > 0.001 {
                PlayerModeTraceShape(mode: mode)
                    .stroke(ForegroundStyle(), lineWidth: strokeBoost)
            }
        }
        .frame(width: size, height: size)
    }
}
