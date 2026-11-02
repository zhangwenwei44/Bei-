import SwiftUI

// MARK: - 音效面板（酷狗风格，参考「音质」页）

/// 🔴 播放页动作行「音效」按钮弹出的面板：选择三频段音效预设。
/// 默认「关闭」（不挂 audioMix，零影响）；选了预设即时生效。
struct SoundEffectPanel: View {
    @ObservedObject private var setting = SoundEffectSetting.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 顶部说明
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppStyle.accent)
                    Text("音效通过实时音频处理实现，仅对当前播放生效")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                ForEach(SoundEffectPreset.allCases) { preset in
                    row(preset)
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("音效")
        .navigationBarTitleDisplayMode(.inline)
        .kugouNavigationBarBackground()
    }

    private func row(_ preset: SoundEffectPreset) -> some View {
        let selected = setting.current == preset
        return Button {
            setting.current = preset
            Haptics.light()
        } label: {
            HStack(spacing: 14) {
                // 左侧图标（与动作行同款三滑块）
                ZStack {
                    SoundEffectGlyph().stroke(
                        selected ? AppStyle.accent : AppStyle.secondaryText,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    SoundEffectKnobs().fill(
                        selected ? AppStyle.accent : AppStyle.secondaryText)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.primaryText)
                    Text(preset.caption)
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppStyle.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.10) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? AppStyle.accent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
