import SwiftUI
import UIKit
import MediaPlayer

// MARK: - 🔴 2026-11-15 第二十三轮：播放器「更多」面板
//
// 用户按酷狗 20.8.4 参考图纠偏：
//  ① 只保留「歌曲信息条 + 8 宫格 + 音量条」，红圈圈起的 20 宫格卡片整体删掉；
//  ② 弹窗容器顶部两角要圆角（原来是一整块方角背景）；
//  ③ 音量条右侧是喇叭图标，不是数字；
//  ④ 留下来的每个按钮都必须有真实功能（分发见 PlayerView / PlayerMoreSheets.swift）。

enum PlayerMoreAction: String, CaseIterable, Identifiable {
    case addToPlaylist, sleepTimer, download, playerStyle
    case lyricsFontSize, speedPitch, quality, soundEffect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addToPlaylist:  return "加到歌单"
        case .sleepTimer:     return "定时关闭"
        case .download:       return "下载"
        case .playerStyle:    return "主题"
        case .lyricsFontSize: return "歌词字号"
        case .speedPitch:     return "调速"
        case .quality:        return "音质选择"
        case .soundEffect:    return "音效"
        }
    }

    /// 只用 iOS 15 起就存在的 SF Symbol，避免真机上出现空格子。
    var symbol: String {
        switch self {
        case .addToPlaylist:  return "plus.square"
        case .sleepTimer:     return "timer"
        case .download:       return "square.and.arrow.down"
        case .playerStyle:    return "square.on.square"
        case .lyricsFontSize: return "textformat"
        case .speedPitch:     return "slider.horizontal.3"
        case .quality:        return "waveform"
        case .soundEffect:    return "speaker.wave.2"
        }
    }
}

/// 只圆上面两个角：底部弹出面板的下半部分要一直贴到屏幕底边。
private struct PlayerMoreTopCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 系统音量滑杆（MPVolumeView 自带细轨道，真机可直接拖动调音量）。
/// 🔴 2026-11-15 第二十四轮：系统默认滑块是个约 30pt 的大白圆，真机上非常扎眼
///    （用户截图 69d888f7「白色圆点小点」）。用 `setVolumeThumbImage` 换成
///    11pt 小圆点，外面留一圈极细灰边，保证在浅灰轨道上仍然看得清。
private struct SystemVolumeSlider: UIViewRepresentable {
    private static let side: CGFloat = 11

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor.black.withAlphaComponent(0.72)
        let side = Self.side
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor(white: 0.80, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0.8, y: 0.8,
                                        width: side - 1.6, height: side - 1.6)).fill()
        }
        view.setVolumeThumbImage(thumb, for: .normal)
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// 半透明遮罩 + 歌曲信息条 + 一块白色圆角网格卡（含音量条）+ 关闭。
/// 🔴 用 overlay 而不是 sheet：iOS 15 的 sheet 背景不透明，透不出后面的播放页。
struct PlayerMorePanel: View {
    let title: String
    let artist: String
    let cover: UIImage?
    let onSelect: (PlayerMoreAction) -> Void
    let onClose: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    /// Home indicator 区域高度。面板要铺到屏幕底边，内容则必须避开它。
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 🔴 2026-11-16：遮罩层独立成一层，只做 opacity 淡入，**不跟随面板滑动**。
            //    以前遮罩和卡片是同一个 ZStack、一起挂 .move(edge:.bottom)：
            //    打开动画期间整块（含全屏黑遮罩）从底部滑上来，屏幕顶部短时间内
            //    根本没有被遮罩盖住，浅灰面板底色(0.96)直接压在明亮的大图上，
            //    看起来就是「弹窗打开时上面闪一下灰色」。分层后遮罩原地淡入，
            //    顶部始终同步变暗，灰闪消失。
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
                .transition(.opacity)

            panelCard
        }
        // 让面板布局区扩展到屏幕底边，浅灰才不会被安全区截断。
        .ignoresSafeArea(edges: .bottom)
    }

    /// 卡片本体：只从底部滑入，不叠加 opacity —— 半透明插值会让浅灰底色在
    /// 圆角/顶部边缘透出一条灰带。compositingGroup 让 clipShape 先合成再动画，
    /// 避免圆角在首帧没裁切干净的闪灰。
    private var panelCard: some View {
        VStack(spacing: 8) {
            songBar
            actionCard
            Button {
                onClose()
            } label: {
                Text("关闭")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        // 🔴 第二十四轮：补足底部安全区，让浅灰面板一直铺到屏幕底边。
        //    旧版只 padding 14，home indicator 区会露出播放页的深色背景，
        //    形成一条突兀黑带（用户截图 69d888f7「底部黑色」）。
        .padding(.bottom, 14 + bottomSafeInset)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97))
        .clipShape(PlayerMoreTopCorners(radius: 20))
        .compositingGroup()
        .transition(.move(edge: .bottom))
    }

    private var songBar: some View {
        HStack(spacing: 10) {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.gray))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(artist).font(.system(size: 12)).foregroundStyle(.gray).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = "\(title) - \(artist)"
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text("复制")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().stroke(Color.black.opacity(0.16), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }

    private var actionCard: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(PlayerMoreAction.allCases) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        VStack(spacing: 7) {
                            // 🔴 2026-11-20：下载图标改成用户给的 Lucide download（与动作行同款）。
                            if item == .download {
                                LucideIcon(icon: .download, size: 25, color: Color.black.opacity(0.78))
                                    .frame(height: 27)
                            } else {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 23, weight: .light))
                                    .foregroundStyle(Color.black.opacity(0.78))
                                    .frame(height: 27)
                            }
                            Text(item.title)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.black.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 10)

            // 🔴 第二十七轮：用户要的是「音量条回到上下两个按钮中间」，并且
            //    **两边喇叭图标不动、只调中间的音量调节条**。
            //    第二十六轮把整块下移过头（距第二行文字约 73pt、距「关闭」仅 28pt）。
            //    面板贴底，绝对位置由「下方」量决定：bottom 0→16、spacing 6→8、
            //    关闭 44→46 让整块上移约 20pt，再把 top 52→22 收掉多余空白，
            //    使音量条到第二行文字 ≈47pt、到「关闭」中心 ≈47pt，正好居中。
            //    两侧喇叭图标的字号/颜色/水平位置一律不改；只有中间 MPVolumeView
            //    的轨道比图标中心高约 7pt，单独用 offset 下移对齐（纯视觉位移，
            //    不参与布局，图标完全不动）。
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.black.opacity(0.62))
                SystemVolumeSlider()
                    .frame(height: 30)
                    .offset(y: 6)
                Image(systemName: "speaker.wave.3")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.black.opacity(0.62))
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }
}
