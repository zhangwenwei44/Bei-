import SwiftUI

// MARK: - 酷狗 20.8.4 风格播放控件（2026-11-10）
//
// 只给「沉浸式封面」主题用：主播放页控制行 + 该主题的歌词页控制行。
// 经典封面 / 歌手写真主题仍走 PlayerView 原来的 SF Symbol 控件行，一行不动。
//
// 为什么要自绘：酷狗这五个图标都不是系统符号 ——
//   ① 顺序播放 = 两条平行右箭头（细线，不是 SF 的 repeat 闭环）
//   ② 上一首/下一首 = 粗实心三角 + 独立竖条，中间留缝
//   ③ 播放暂停 = 半透明白色圆盘 + 实心三角 / 双竖条
//   ④ 播放列表 = 顶部一条「小三角 + 横线」+ 两条横线（歌词页带蓝色数量角标）
// 系统里找不到同名符号，硬套 `repeat` / `list.bullet` 就是用户说的「不是酷狗样式」。

/// 实心三角（pointsRight = 尖朝右）。
private struct KugouTriangle: Shape {
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// 顺序播放：两条水平细线 + 右端斜向上的箭头尖。
private struct KugouDoubleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x0 = rect.minX + 1
        let x1 = rect.maxX - 1
        let tip: CGFloat = 7
        let y1 = rect.minY + rect.height * 0.30
        let y2 = rect.maxY - rect.height * 0.30
        p.move(to: CGPoint(x: x0, y: y1))
        p.addLine(to: CGPoint(x: x1, y: y1))
        p.move(to: CGPoint(x: x1 - tip, y: y1 - tip))
        p.addLine(to: CGPoint(x: x1, y: y1))
        p.move(to: CGPoint(x: x0, y: y2))
        p.addLine(to: CGPoint(x: x1, y: y2))
        p.move(to: CGPoint(x: x1 - tip, y: y2 - tip))
        p.addLine(to: CGPoint(x: x1, y: y2))
        return p
    }
}

/// 播放模式：顺序 / 随机 / 单曲循环，点一下由 store.cycleMode() 切换。
struct KugouModeGlyph: View {
    let mode: PlaybackMode
    var body: some View {
        Group {
            switch mode {
            case .order:
                KugouDoubleArrow()
                    .stroke(Color.white.opacity(0.92),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 28, height: 24)
            case .shuffle:
                Image(systemName: "shuffle")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
            case .single:
                Image(systemName: "repeat.1")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: 34, height: 30)
    }
}

/// 上一首 / 下一首：竖条 + 实心三角，中间留 3pt 缝（酷狗实测）。
struct KugouStepGlyph: View {
    let forward: Bool
    var body: some View {
        HStack(spacing: 3) {
            if forward {
                KugouTriangle(pointsRight: true)
                    .fill(.white)
                    .frame(width: 22, height: 27)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 4.5, height: 29)
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 4.5, height: 29)
                KugouTriangle(pointsRight: false)
                    .fill(.white)
                    .frame(width: 22, height: 27)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// 播放 / 暂停：半透明白色圆盘 + 白色实心三角 / 双竖条。
struct KugouPlayGlyph: View {
    let isPlaying: Bool
    let isLoading: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.13))
            if isLoading {
                ProgressView().tint(.white)
            } else if isPlaying {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 6, height: 26)
                    RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 6, height: 26)
                }
            } else {
                KugouTriangle(pointsRight: true)
                    .fill(.white)
                    .frame(width: 25, height: 29)
                    .offset(x: 2)
            }
        }
        .frame(width: 66, height: 66)
    }
}

/// 播放列表：三条横线，第一条左端带一个小播放三角。
/// 歌词页版右上角再挂一个蓝色圆形数量角标（酷狗同款）。
struct KugouQueueGlyph: View {
    let badge: Int?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    KugouTriangle(pointsRight: true)
                        .fill(.white.opacity(0.92))
                        .frame(width: 7, height: 8)
                    Capsule().fill(.white.opacity(0.92)).frame(width: 14, height: 2)
                }
                Capsule().fill(.white.opacity(0.92)).frame(width: 23, height: 2)
                Capsule().fill(.white.opacity(0.92)).frame(width: 23, height: 2)
            }
            .frame(width: 26, height: 24)
            if let badge, badge > 0 {
                Text(badge > 99 ? "99+" : "\(badge)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Circle().fill(Color(red: 0.20, green: 0.68, blue: 0.98)))
                    .offset(x: 12, y: -10)
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// 整行五个按钮：模式 / 上一首 / 播放暂停 / 下一首 / 队列。
/// 与主播放页 classicDeckControls 完全等价的功能，只换外观。
struct KugouControlsRow: View {
    @EnvironmentObject private var store: PlayerStore
    /// 歌词页显示队列数量角标，主播放页不显示（与酷狗一致）。
    var showsQueueBadge: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Button { store.cycleMode(); Haptics.light() } label: {
                KugouModeGlyph(mode: store.mode)
                    .frame(width: 44, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.step(-1); Haptics.light() } label: {
                KugouStepGlyph(forward: false)
                    .frame(width: 52, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.toggle(); Haptics.soft() } label: {
                KugouPlayGlyph(isPlaying: store.isPlaying,
                               isLoading: store.isLoading || (store.isBuffering && store.isPlaying))
                    .frame(width: 66, height: 66)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.step(1); Haptics.light() } label: {
                KugouStepGlyph(forward: true)
                    .frame(width: 52, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.isQueuePresented = true; Haptics.light() } label: {
                KugouQueueGlyph(badge: showsQueueBadge ? store.queue.count : nil)
                    .frame(width: 44, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 68)
    }
}
