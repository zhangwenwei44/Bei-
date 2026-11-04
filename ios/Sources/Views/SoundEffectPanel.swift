import SwiftUI

// MARK: - 音效面板（全屏深色，参考「蝰蛇音效」页）

/// 🔴 v2.9.26 重做为**全屏**页面（之前是卡片 sheet）：
/// 自定义返回栏 + 渐变横幅 + 预设卡片列表（单选，点一下即时生效）+ 底部「当前音效」栏 + 总开关。
/// 预设：关闭 / 超重低音 / 清澈人声 / 环绕立体 / 现场 Live。
struct SoundEffectPanel: View {
    @ObservedObject private var setting = SoundEffectSetting.shared
    @Environment(\.dismiss) private var dismiss
    /// 记忆上次开启的预设，关闭后再次开启回到这里
    @AppStorage("aurora.soundEffectLastOn") private var lastOnRaw: String = SoundEffectPreset.bass.rawValue

    private var lastOn: SoundEffectPreset {
        SoundEffectPreset(rawValue: lastOnRaw) ?? .bass
    }
    private var isOn: Bool { setting.current != .off }

    var body: some View {
        ZStack {
            // 深色全屏背景（近黑）
            LinearGradient(colors: [Color(white: 0.04), Color(white: 0.09)],
                          startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 14) {
                        banner
                        LazyVStack(spacing: 12) {
                            ForEach(SoundEffectPreset.allCases) { preset in
                                row(preset)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
                bottomBar
            }
        }
    }

    // MARK: - 顶栏（自定义返回 + 居中标题）

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 0)
            Text("音效")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            // 右侧占位，使标题真正居中
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 8)
        .background(Color(white: 0.04))
    }

    // MARK: - 渐变横幅卡片

    private var banner: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.85),
                                    Color(red: 0.20, green: 0.45, blue: 0.95)],
                          startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 14) {
                // 左侧音效图标
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.18))
                    SoundEffectGlyph().stroke(.white,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    SoundEffectHandles().stroke(.white,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("音效")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("实时音频处理，仅对当前播放生效")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 预设卡片（单选）

    private func row(_ preset: SoundEffectPreset) -> some View {
        let selected = setting.current == preset
        return Button {
            select(preset)
            Haptics.light()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    SoundEffectGlyph().stroke(
                        selected ? AppStyle.accent : .white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    SoundEffectHandles().stroke(
                        selected ? AppStyle.accent : .white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? AppStyle.accent : .white)
                    Text(preset.caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AppStyle.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.14) : Color(white: 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? AppStyle.accent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部「当前音效」栏 + 总开关

    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("当前音效")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Text(setting.current.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                setting.current = on ? lastOn : .off
            })) { }
                .toggleStyle(SwitchToggleStyle(tint: AppStyle.accent))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(white: 0.07))
    }

    private func select(_ preset: SoundEffectPreset) {
        setting.current = preset
        if preset != .off { lastOnRaw = preset.rawValue }
    }
}
