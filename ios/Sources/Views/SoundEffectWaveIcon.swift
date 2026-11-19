import SwiftUI

/// 🔴 2026-11-19：音效页重新设计的图标。
/// 用 5 根高低不同的圆角频谱柱替代播放器动作行那套「三滑块」旧图标，
/// 只用于音效页与自定义均衡器，播放器动作行图标保持原有参考图不被改变。
struct SoundEffectWaveIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let ox = rect.midX - side / 2
        let oy = rect.midY - side / 2
        // (x, 高度) 以 24×24 为设计稿坐标
        let bars: [(CGFloat, CGFloat)] = [
            (1.5, 8.5),
            (6.0, 15.5),
            (10.5, 11.5),
            (15.0, 18.5),
            (19.5, 6.5)
        ]
        let barWidth: CGFloat = 2.6
        var p = Path()
        for (x, h) in bars {
            let r = CGRect(x: ox + x / 24 * side,
                           y: oy + (24 - h) / 2 / 24 * side,
                           width: barWidth / 24 * side,
                           height: h / 24 * side)
            let radius = barWidth / 24 * side / 2
            p.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius))
        }
        return p
    }
}
