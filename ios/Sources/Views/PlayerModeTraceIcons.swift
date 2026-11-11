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

/// 把描摹轮廓按自身 viewBox 等比缩放居中到给定矩形，形状严格 1:1。
private struct PlayerModeTraceShape: Shape {
    let mode: PlaybackMode

    func path(in rect: CGRect) -> Path {
        let spec = ModeTrace.spec(for: mode)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let scale = min(rect.width / spec.box.width, rect.height / spec.box.height)
        let ox = rect.midX - spec.box.width * scale / 2
        let oy = rect.midY - spec.box.height * scale / 2
        func p(_ point: CGPoint) -> CGPoint {
            CGPoint(x: ox + point.x * scale, y: oy + point.y * scale)
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

    var body: some View {
        PlayerModeTraceShape(mode: mode)
            .fill(ForegroundStyle(), style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
    }
}
