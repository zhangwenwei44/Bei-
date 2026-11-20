import SwiftUI

/// 音质选择页：浅色 = 白色 + 蓝色主色；🔴 2026-11-21 深色模式跟随 App 主题（不再强制浅色）。
///
/// 两种呈现方式：
/// 1. 设置页 push（embeddedInPanel = false，onDismiss = nil）：整页 + 系统导航栏。
/// 2. 播放器底部面板（embeddedInPanel = true）：只输出内容，横条/背景/圆角由 `CompactPanelOverlay` 统一提供，
///    高度随内容自适应 —— 🔴 修复旧版固定 0.60 屏高导致的「上下大片留白」。
struct QualitySettingsView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    /// 从播放器「更多」以 sheet 打开时传入（兼容旧调用）：顶部横条 + 横条关闭。
    var onDismiss: (() -> Void)? = nil
    /// 🔴 2026-11-21：嵌在 `CompactPanelOverlay` 里时为 true —— 只输出纯内容，
    ///    不画横条/背景/导航栏、不限高，交给外层面板贴合内容高度。
    var embeddedInPanel: Bool = false

    // 🔴 2026-11-21：全部改用 AppStyle 动态语义色，深色模式自动变深色卡片。
    private let accent = AppStyle.accent
    private let pageBg = AppStyle.background
    private let cardBg = AppStyle.surface
    private let divider = AppStyle.stroke
    private let textPrimary = AppStyle.primaryText
    private let textSecondary = AppStyle.secondaryText
    private let textTertiary = AppStyle.tertiaryText

    /// 当前使用的音源（最高优先级可用音源）。
    private var currentSource: ThirdPartySource? { sourceStore.currentSource }
    /// 当前音源支持的档位；检测不到标记时回退到全部可选档位。
    private var supportedQualities: [MusicQuality] {
        let list = currentSource?.supportedQualities ?? []
        return list.isEmpty ? MusicQuality.selectableCases : list
    }

    var body: some View {
        Group {
            if embeddedInPanel {
                // 面板内：纯内容，高度自适应（外层已包横条 + 圆角背景 + 点击关闭）
                pageContent
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    pageContent
                }
                .frame(height: onDismiss == nil ? nil : UIScreen.main.bounds.height * 0.60)
                .background(pageBg.ignoresSafeArea())
                .navigationTitle(onDismiss == nil ? "音质" : "")
                .navigationBarTitleDisplayMode(.inline)
                .kugouNavigationBarBackground()
            }
        }
    }

    /// 纯内容（横条 + 当前卡片 + 档位列表）。横条仅在非面板模式、从 sheet 打开时显示。
    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if onDismiss != nil {
                Button { onDismiss?() } label: {
                    Capsule()
                        .fill(divider)
                        .frame(width: 38, height: 5)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }

            currentQualityCard
                .padding(.horizontal, 16)
                .padding(.top, onDismiss == nil ? 16 : 0)

            VStack(spacing: 0) {
                ForEach(supportedQualities) { quality in
                    Button {
                        sourceStore.quality = quality
                        Haptics.light()
                    } label: {
                        qualityRow(quality)
                    }
                    .buttonStyle(.plain)
                    if quality != supportedQualities.last {
                        Divider()
                            .background(divider)
                            .padding(.leading, 62)
                    }
                }
            }
            .background(cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(divider, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .padding(.bottom, 12)
    }

    // MARK: - 顶部当前选择卡片

    private var currentQualityCard: some View {
        let q = sourceStore.quality
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.12))
                    Image(systemName: q.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(q.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                        if q.isAdvanced {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(accent)
                        }
                    }
                    Text("当前音源：\(currentSource?.name ?? "未知音源")")
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(q.featureLine)
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accent)
                    Text("当前")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(accent, lineWidth: 1.5)
                )
        )
    }

    // MARK: - 列表行

    private func qualityRow(_ quality: MusicQuality) -> some View {
        let selected = sourceStore.quality == quality
        let downgraded = sourceStore.cellularFallback && network.isCellular && quality != .standard
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? accent.opacity(0.12) : AppStyle.surfaceHigh)
                Image(systemName: quality.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? accent : textSecondary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(quality.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? accent : textPrimary)
                    Text(quality.sizeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(textTertiary)
                    if quality.isAdvanced {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(accent.opacity(0.8))
                    }
                }
                Text(downgraded ? "蜂窝网络下已自动降为高品音质" : quality.detailLine)
                    .font(.system(size: 12))
                    .foregroundStyle(downgraded ? accent : textSecondary)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(selected ? accent.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - 档位展示信息

extension MusicQuality {
    /// 档位图标
    var icon: String {
        switch self {
        case .standard: return "waveform"
        case .higher: return "waveform.path"
        case .exHigh: return "music.note.list"
        case .lossless: return "crown.fill"
        case .hires: return "sparkles"
        }
    }

    /// 当前选择卡的一行说明
    var featureLine: String {
        switch self {
        case .standard: return "好音质省流最佳选择"
        case .higher: return "最高 320kbps 主流清晰纯享听感"
        case .exHigh: return "高码率 320 kbps，接近 CD 听感"
        case .lossless: return "音源支持时获取 FLAC 无损音源"
        case .hires: return "音源支持时获取 FLAC 24bit Hi-Res"
        }
    }

    /// 该档位向音源请求的目标格式 / 码率（客观事实，非写死假体积）。
    var sizeLabel: String {
        switch self {
        case .standard: return "128 kbps"
        case .higher: return "320 kbps"
        case .exHigh: return "320 kbps"
        case .lossless: return "FLAC 无损"
        case .hires: return "FLAC 24bit"
        }
    }

    /// 列表里的说明
    var detailLine: String {
        switch self {
        case .standard: return "好音质省流最佳选择"
        case .higher: return "最高 320kbps 主流清晰纯享听感"
        case .exHigh: return "高码率 320 kbps，接近 CD 听感"
        case .lossless: return "FLAC 无损音质，需要音源支持"
        case .hires: return "FLAC 24bit Hi-Res，需要音源支持"
        }
    }

    /// 是否属于"高级"档位（列表里带钻石角标）
    var isAdvanced: Bool {
        switch self {
        case .standard, .higher: return false
        case .exHigh, .lossless, .hires: return true
        }
    }
}

/// 按网络环境设置（从音质页 push 进来，跟随深浅主题）。
struct NetworkQualityView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    private let accent = AppStyle.accent

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $sourceStore.cellularFallback) {
                    Text("蜂窝网络自动降为高品音质")
                        .foregroundStyle(AppStyle.primaryText)
                }
                .tint(accent)
            } header: {
                Text("流量环境")
            } footer: {
                Text(network.isCellular
                     ? "当前正在使用蜂窝网络，关闭后仍按所选音质播放（更耗流量）。"
                     : "当前不是蜂窝网络。开启后，用 4G/5G 播放时会自动降到高品音质以省流量。")
                    .font(.system(size: 12))
            }
        }
        .navigationTitle("不同网络环境下的音质")
        .navigationBarTitleDisplayMode(.inline)
        .kugouNavigationBarBackground()
    }
}
