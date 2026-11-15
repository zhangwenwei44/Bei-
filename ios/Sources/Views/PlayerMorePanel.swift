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
    case cast, speedPitch, quality, soundEffect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addToPlaylist:  return "加到歌单"
        case .sleepTimer:     return "定时关闭"
        case .download:       return "下载"
        case .playerStyle:    return "播放器样式"
        case .cast:           return "投播"
        case .speedPitch:     return "调速·升降调"
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
        case .cast:           return "airplayaudio"
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

/// 系统音量滑杆（MPVolumeView 自带细轨道 + 圆点，真机可直接拖动调音量）。
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor.black.withAlphaComponent(0.72)
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

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 10) {
                songBar
                actionCard
                Button {
                    onClose()
                } label: {
                    Text("关闭")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .background(Color(red: 0.96, green: 0.96, blue: 0.97))
            .clipShape(PlayerMoreTopCorners(radius: 20))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }

    private var actionCard: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(PlayerMoreAction.allCases) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 23, weight: .light))
                                .foregroundStyle(Color.black.opacity(0.78))
                                .frame(height: 27)
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
            .padding(.bottom, 8)

            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.black.opacity(0.7))
                SystemVolumeSlider()
                    .frame(height: 30)
                Image(systemName: "speaker.wave.3")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.black.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }
}
