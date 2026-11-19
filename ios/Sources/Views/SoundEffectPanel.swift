import SwiftUI

// MARK: - 音效面板（🔴 2026-11-19 改为白色背景 + 新图标 + 自定义均衡器）

/// 全屏页面：自定义返回栏 + 渐变横幅 + 预设卡片列表（单选，点一下即时生效）
/// + 「自定义音效」均衡器入口 + 底部「当前音效」栏 + 总开关。
/// 预设：关闭 / 超重低音 / 清澈人声 / 环绕立体 / 现场 Live / 自定义音效。
struct SoundEffectPanel: View {
    @ObservedObject private var setting = SoundEffectSetting.shared
    @Environment(\.dismiss) private var dismiss
    /// 记忆上次开启的预设，关闭后再次开启回到这里
    @AppStorage("aurora.soundEffectLastOn") private var lastOnRaw: String = SoundEffectPreset.bass.rawValue
    /// 自定义均衡器弹层（单个 sheet，遵循 iOS 15 链式 sheet 只认最后一个的红线）
    @State private var showEqualizer = false

    private var lastOn: SoundEffectPreset {
        SoundEffectPreset(rawValue: lastOnRaw) ?? .bass
    }
    private var isOn: Bool { setting.current != .off }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
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
        .preferredColorScheme(.light)
        // 🔴 自定义/预设只要处于开启态，都记为「上次开启」，关掉总开关后可原样恢复。
        .onChange(of: setting.current) { new in
            if new != .off { lastOnRaw = new.rawValue }
        }
        .sheet(isPresented: $showEqualizer) {
            SoundEffectEqualizerView()
        }
    }

    // MARK: - 顶栏（自定义返回 + 居中标题）

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 0)
            Text("音效")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppStyle.primaryText)
            Spacer(minLength: 0)
            // 右侧占位，使标题真正居中
            Color.clear.frame(width: 44, height: 44)
        }
        .frame(height: 52)
        .background(Color.white)
    }

    // MARK: - 渐变横幅卡片

    private var banner: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [AppStyle.accent.opacity(0.20), AppStyle.accent.opacity(0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppStyle.accent.opacity(0.16))
                    SoundEffectWaveIcon()
                        .fill(AppStyle.accent)
                        .padding(11)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("音效")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)
                    Text("实时音频处理，仅对当前播放生效")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 预设卡片（单选；自定义项打开均衡器）

    private func row(_ preset: SoundEffectPreset) -> some View {
        let selected = setting.current == preset
        return Button {
            if preset == .custom {
                showEqualizer = true
            } else {
                select(preset)
            }
            Haptics.light()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    SoundEffectWaveIcon()
                        .fill(selected ? AppStyle.accent : Color(uiColor: UIColor(white: 0.45, alpha: 1)))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? AppStyle.accent : AppStyle.primaryText)
                    Text(preset.caption)
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AppStyle.accent)
                } else if preset == .custom {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppStyle.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? AppStyle.accent.opacity(0.10) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? AppStyle.accent.opacity(0.45)
                                     : Color(uiColor: UIColor(white: 0.90, alpha: 1)),
                            lineWidth: selected ? 1 : 0.5)
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
                    .foregroundStyle(AppStyle.secondaryText)
                Text(setting.current.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
            }
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                setting.current = on ? lastOn : .off
            })) { }
                .toggleStyle(SwitchToggleStyle(tint: AppStyle.accent))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color(uiColor: UIColor(white: 0.90, alpha: 1)))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private func select(_ preset: SoundEffectPreset) {
        setting.current = preset
        if preset != .off { lastOnRaw = preset.rawValue }
    }
}
