import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

// MARK: - 🔴 2026-11-15 第二十二轮：播放器「更多」面板（酷狗 20.8.4 同款 4 列网格）

enum PlayerMoreAction: String, CaseIterable, Identifiable {
    case addToPlaylist, sleepTimer, download, playerStyle
    case cast, speedPitch, quality, soundEffect
    case landscape, heatSong, speakerBoost, mv
    case share, lyricSettings, playSettings, flowerMode
    case fishMode, songTransition, aiSing, ringtone
    case accompany, karaoke, segmentLoop, landscapeKTV
    case danmaku, magicColor, humming, likeSong

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
        case .landscape:      return "横屏"
        case .heatSong:       return "歌曲加热"
        case .speakerBoost:   return "外放增强"
        case .mv:             return "MV"
        case .share:          return "分享"
        case .lyricSettings:  return "歌词设置"
        case .playSettings:   return "播放设置"
        case .flowerMode:     return "养花模式"
        case .fishMode:       return "养鱼模式"
        case .songTransition: return "歌曲过渡"
        case .aiSing:         return "AI帮唱"
        case .ringtone:       return "设为铃声"
        case .accompany:      return "伴唱"
        case .karaoke:        return "K歌"
        case .segmentLoop:    return "片段循环"
        case .landscapeKTV:   return "横屏KTV"
        case .danmaku:        return "弹幕"
        case .magicColor:     return "炫彩特效"
        case .humming:        return "哼唱识曲"
        case .likeSong:       return "喜欢"
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
        case .landscape:      return "rectangle.on.rectangle"
        case .heatSong:       return "flame"
        case .speakerBoost:   return "speaker.wave.3"
        case .mv:             return "play.rectangle"
        case .share:          return "square.and.arrow.up"
        case .lyricSettings:  return "text.bubble"
        case .playSettings:   return "gearshape"
        case .flowerMode:     return "leaf"
        case .fishMode:       return "drop"
        case .songTransition: return "shuffle"
        case .aiSing:         return "waveform.circle"
        case .ringtone:       return "bell"
        case .accompany:      return "music.note"
        case .karaoke:        return "mic"
        case .segmentLoop:    return "repeat"
        case .landscapeKTV:   return "tv"
        case .danmaku:        return "message"
        case .magicColor:     return "sparkles"
        case .humming:        return "music.note.list"
        case .likeSong:       return "heart"
        }
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

/// 半透明遮罩 + 歌曲信息条 + 两块白色圆角网格卡 + 关闭。
/// 🔴 用 overlay 而不是 sheet：iOS 15 的 sheet 背景不透明，透不出后面的播放页。
struct PlayerMorePanel: View {
    let title: String
    let artist: String
    let cover: UIImage?
    let onSelect: (PlayerMoreAction) -> Void
    let onClose: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)
    private let topItems = Array(PlayerMoreAction.allCases.prefix(8))
    private let bottomItems = Array(PlayerMoreAction.allCases.dropFirst(8))
    @State private var volumePercent: Int = Int(AVAudioSession.sharedInstance().outputVolume * 100)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 10) {
                songBar
                card(items: topItems, withVolume: true)
                card(items: bottomItems, withVolume: false)
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

    private func card(items: [PlayerMoreAction], withVolume: Bool) -> some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
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
            .padding(.bottom, withVolume ? 8 : 18)

            if withVolume {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.black.opacity(0.7))
                    SystemVolumeSlider()
                        .frame(height: 30)
                    Text("\(volumePercent)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }
}
