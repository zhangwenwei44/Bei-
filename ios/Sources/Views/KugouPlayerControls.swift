import SwiftUI

// MARK: - 酷狗 20.8.4 风格播放控件（2026-11-10）
//
// 只给「沉浸式封面」主题用：主播放页控制行 + 该主题的歌词页控制行。
// 经典封面 / 歌手写真主题仍走 PlayerView 原来的 SF Symbol 控件行，一行不动。
//
// 🔴 2026-11-10 用户回退：顺序播放 / 列表改回经典主题的 SF Symbol
//    （repeat / shuffle / repeat.1 与 list.bullet），并去掉队列蓝色数量角标。
//    自绘只保留中间三个：上一首/下一首（实心三角+竖条）、播放暂停（半透明白圆盘）。
//    整行尺寸同时缩小一档（圆盘 66→52、行高 68→54）。
//    KugouDoubleArrow 作为历史字形保留，已不再参与渲染。

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
/// 🔴 2026-11-10 用户要求「顺序播放按钮改回以前的」：不再用酷狗双箭头自绘，
///    与经典封面主题完全一致 —— repeat / shuffle / repeat.1 三个 SF Symbol。
struct KugouModeGlyph: View {
    let mode: PlaybackMode
    private var icon: String {
        switch mode {
        case .order:   return "repeat"
        case .shuffle: return "shuffle"
        case .single:  return "repeat.1"
        }
    }
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 34, height: 30)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// 上一首 / 下一首：竖条 + 实心三角，中间留缝（酷狗实测）。
/// 🔴 2026-11-10 用户要求「播放控件改小点」：三角 22×27→18×22、竖条 4.5×29→3.5×24。
/// 🔴 2026-11-11 用户再要求「上一首下一首按钮改小点」：三角 18×22→15×18.5、
///    竖条 3.5×24→3×20。只缩字形，按钮 .frame(46×48) 命中区保持不变（不然点不到）。
struct KugouStepGlyph: View {
    let forward: Bool
    var body: some View {
        HStack(spacing: 2) {
            if forward {
                KugouTriangle(pointsRight: true)
                    .fill(.white)
                    .frame(width: 15, height: 18.5)
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(.white)
                    .frame(width: 3, height: 20)
            } else {
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(.white)
                    .frame(width: 3, height: 20)
                KugouTriangle(pointsRight: false)
                    .fill(.white)
                    .frame(width: 15, height: 18.5)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// 播放 / 暂停：半透明白色圆盘 + 白色实心三角 / 双竖条。
/// 🔴 2026-11-10 用户要求「播放控件改小点」：圆盘 66→52，内部字形同比收小。
struct KugouPlayGlyph: View {
    let isPlaying: Bool
    let isLoading: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.13))
            if isLoading {
                ProgressView().tint(.white)
            } else if isPlaying {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.2).fill(.white).frame(width: 5, height: 20)
                    RoundedRectangle(cornerRadius: 1.2).fill(.white).frame(width: 5, height: 20)
                }
            } else {
                KugouTriangle(pointsRight: true)
                    .fill(.white)
                    .frame(width: 20, height: 23)
                    .offset(x: 2)
            }
        }
        .frame(width: 52, height: 52)
    }
}

/// 播放列表。
/// 🔴 2026-11-10 用户要求「列表也改回以前的」：与经典封面主题一致用 list.bullet，
///    不再用酷狗三横线自绘，也不再挂蓝色数量角标。
struct KugouQueueGlyph: View {
    var body: some View {
        Image(systemName: "list.bullet")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 34, height: 30)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// 整行五个按钮：模式 / 上一首 / 播放暂停 / 下一首 / 队列。
/// 与主播放页 classicDeckControls 完全等价的功能，只换外观。
struct KugouControlsRow: View {
    @EnvironmentObject private var store: PlayerStore

    var body: some View {
        HStack(spacing: 0) {
            Button { store.cycleMode(); Haptics.light() } label: {
                KugouModeGlyph(mode: store.mode)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.step(-1); Haptics.light() } label: {
                KugouStepGlyph(forward: false)
                    .frame(width: 46, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.toggle(); Haptics.soft() } label: {
                KugouPlayGlyph(isPlaying: store.isPlaying,
                               isLoading: store.isLoading || (store.isBuffering && store.isPlaying))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.step(1); Haptics.light() } label: {
                KugouStepGlyph(forward: true)
                    .frame(width: 46, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button { store.isQueuePresented = true; Haptics.light() } label: {
                KugouQueueGlyph()
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
    }
}
