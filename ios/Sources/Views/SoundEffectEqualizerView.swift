import SwiftUI

/// 🔴 2026-11-19：音效页新增的 10 段自定义均衡器。
/// 参数保存在 SoundEffectSetting，应用后通过 MTAudioProcessingTap 实时生效。
struct SoundEffectEqualizerView: View {
    @ObservedObject private var setting = SoundEffectSetting.shared
    @Environment(\.dismiss) private var dismiss

    @State private var bands: [Float] = SoundEffectSetting.shared.customBands
    @State private var master: Float = SoundEffectSetting.shared.customMaster

    private let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        banner
                        equalizerHint
                        equalizerStrip
                        masterRow
                        resetRow
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.secondaryText)
            Spacer(minLength: 0)
            Text("自定义均衡器")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            Spacer(minLength: 0)
            Button("应用") {
                setting.applyCustom(bands: bands, master: master)
                dismiss()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppStyle.accent)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.white)
    }

    private var banner: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppStyle.accent.opacity(0.14))
                SoundEffectWaveIcon()
                    .fill(AppStyle.accent)
                    .padding(10)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("精细调节你的听感")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                Text("每个频点独立增减，实时作用于正在播放的歌曲")
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            LinearGradient(colors: [AppStyle.accent.opacity(0.12), AppStyle.accent.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.horizontal, 16)
    }

    private var equalizerHint: some View {
        HStack {
            Text("频段（Hz）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppStyle.primaryText)
            Spacer(minLength: 0)
            Text("范围 -12 ~ +12 dB")
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .padding(.horizontal, 16)
    }

    private var equalizerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<labels.count, id: \.self) { index in
                    equalizerColumn(index)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: UIColor(white: 0.97, alpha: 1)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func equalizerColumn(_ index: Int) -> some View {
        VStack(spacing: 8) {
            Text(String(format: "%+.1f", Double(bands[index])))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppStyle.secondaryText)
                .frame(width: 34)
            VerticalGainSlider(value: $bands[index], range: -12...12)
            Text(labels[index])
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppStyle.tertiaryText)
        }
        .frame(width: 38)
    }

    private var masterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("总增益")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 0)
                Text(String(format: "%+.1f dB", Double(master)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppStyle.secondaryText)
            }
            Slider(value: $master, in: -6...6, step: 0.5)
                .accentColor(AppStyle.accent)
        }
        .padding(14)
        .background(Color(uiColor: UIColor(white: 0.97, alpha: 1)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var resetRow: some View {
        Button {
            bands = SoundEffectSetting.defaultBands
            master = 0
            setting.resetCustom()
        } label: {
            Text("恢复默认（全部 0 dB）")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppStyle.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color(uiColor: UIColor(white: 0.95, alpha: 1)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

/// 竖向增益推子：不依赖 UIKit，也不用旋转 Slider（旋转后命中区会错）。
private struct VerticalGainSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    private var normalized: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return CGFloat((value - range.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let ratio = min(1, max(0, normalized))
            let filled = h * ratio
            let knobY = max(0, min(h - 18, h - filled - 9))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(uiColor: UIColor(white: 0.89, alpha: 1)))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppStyle.accent.opacity(0.35))
                    .frame(height: filled)
                    .offset(y: h - filled)
                Circle()
                    .fill(AppStyle.accent)
                    .frame(width: 18, height: 18)
                    .offset(y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let y = min(h, max(0, g.location.y))
                        let n = 1 - CGFloat(y / max(h, 1))
                        value = range.lowerBound + Float(n) * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(width: 30, height: 180)
    }
}
