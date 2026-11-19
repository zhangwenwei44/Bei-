import SwiftUI

/// 🔴 2026-11-17：音质选择页改为**白色背景 + 蓝色主色**（用户要求「改成白色背景，
/// 排版再美化一下」）。保留真实码率显示与客观档位标注，不再有写死的假体积。
///
/// 版式：
/// 1. 顶部「当前选择」单卡（大字档位名 + 档位名称 + 特性说明 + 当前勾）
/// 2. 中部「高级音质」列表（图标 + 档位 + 目标码率 + 说明 + 选中勾）
/// 3. 底部网络环境入口 + 一条客观说明
struct QualitySettingsView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    // 浅色主题配色（跟随 App 的蓝色主色，不再是深色+金）
    private let accent = AppStyle.accent
    // 🔴 2026-11-19：背景改成跟顶栏一致的纯白（用户要求）。
    private let pageBg = Color.white
    private let cardBg = Color.white
    private let divider = Color(uiColor: UIColor(white: 0.90, alpha: 1))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── 顶部：当前选择音质卡片 ───────────────────────────
                // 🔴 2026-11-19：右上角改成显示当前使用的音源名。
                sectionHeader(title: "音质选择", trailing: currentSource?.name ?? "当前播放音质", top: 16)
                currentQualityCard
                    .padding(.horizontal, 16)

                // ── 中部：高级音质列表 ───────────────────────────────
                // 🔴 2026-11-19：只列出当前音源支持的档位，点击即选择该档。
                sectionHeader(title: "高级音质", trailing: "当前音源支持的档位", top: 24, diamond: true)

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

                // ── 底部：按网络环境设置 ──────────────────────────────
                NavigationLink {
                    NetworkQualityView()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(accent.opacity(0.12))
                            Image(systemName: "wifi")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("不同网络环境下的音质")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(textPrimary)
                            // 🔴 2026-11-19：改成显示当前选择的音质档位。
                            Text("当前：\(sourceStore.quality.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(textTertiary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(divider, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 18)

                Text("说明：实际播放音质取决于音源本身是否提供该档位，选择更高档位不会凭空提升码率。")
                    .font(.system(size: 11))
                    .foregroundStyle(textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            .padding(.bottom, 30)
        }
        .background(pageBg.ignoresSafeArea())
        .navigationTitle("音质")
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 白底页必须强制浅色，否则系统深色模式下 AppStyle 动态色会解析成白字。
        .preferredColorScheme(.light)
        .kugouNavigationBarBackground(UIColor.white, titleColor: UIColor(white: 0.12, alpha: 1))
    }

    private func sectionHeader(title: String, trailing: String, top: CGFloat, diamond: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(textPrimary)
            if diamond {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.system(size: 11))
                .foregroundStyle(textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, top)
        .padding(.bottom, 10)
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
                    // 🔴 2026-11-18（二改）：用户要求音质检测标签改回显示音质名称，
                    //    不再展示「实测 XXX kbps」。这里直接显示当前档位名。
                    Text("当前音质：\(q.title)")
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
                    .fill(selected ? accent.opacity(0.12) : Color(uiColor: UIColor(white: 0.95, alpha: 1)))
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

/// 按网络环境设置（从音质页 push 进来，白色主题）。
private struct NetworkQualityView: View {
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
        .navigationTitle("按网络环境")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .kugouNavigationBarBackground(UIColor.white,
                                      titleColor: UIColor(white: 0.12, alpha: 1))
    }
}
