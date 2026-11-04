import SwiftUI

/// 🔴 v2.9.27：音质选择页重做为**深色背景 + 黄色（金）字体**，参考用户给的酷狗「音质」页。
///
/// 版式对齐参考图：
/// 1. 顶部横向特性卡（每张卡 = 一个音质档位 + 能力说明）
/// 2. 中部「高级音质」列表（档位名 + 体积/码率标注 + 说明 + 右侧选中勾）
/// 3. 底部「设置不同网络环境下的播放音质」入口
///
/// 语义上与酷狗有两点刻意区别（不能虚假宣传）：
/// · 标题写「高级音质」而不是「会员专享」—— 本 App 没有会员体系；
/// · 杜比全景声 / DTS:X 这类需要官方授权解码的效果不写进来，
///   卡片和列表列的都是**音源真正支持的格式档位**（128k / 320k / flac / flac24bit）。
struct QualitySettingsView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    // 深色主题配色（不跟随系统，强制深色 —— 参考图的黑底金字）
    private let gold = Color(red: 1.0, green: 0.82, blue: 0.30)
    private let bg = Color(white: 0.05)
    private let cardBg = Color(white: 0.10)
    private let listBg = Color(white: 0.08)
    private let divider = Color.white.opacity(0.10)
    private let textPrimary = Color.white
    private let textSecondary = Color.white.opacity(0.55)
    private let textTertiary = Color.white.opacity(0.35)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── 顶部：当前选择音质卡片（单张，不横向滑动） ──────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("音质选择")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(gold)
                        Spacer(minLength: 8)
                        Text("当前播放音质")
                            .font(.system(size: 12))
                            .foregroundStyle(textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    // 🔴 v2.9.28：去掉横向滑动特性卡（用户要求：不要横滑显示全部音质），
                    // 改为「当前选择」单张卡片，下面音质列表再逐档列出。
                    currentQualityCard
                        .padding(.horizontal, 16)
                }

                // ── 中部：高级音质列表 ───────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("高级音质")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(gold)
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(gold)
                        Spacer(minLength: 8)
                        Text("按音源实际支持的档位播放")
                            .font(.system(size: 11))
                            .foregroundStyle(textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                    .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach(MusicQuality.allCases) { quality in
                            Button {
                                sourceStore.quality = quality
                                Haptics.light()
                            } label: {
                                qualityRow(quality)
                            }
                            .buttonStyle(.plain)
                            if quality != MusicQuality.allCases.last {
                                Divider().background(divider).padding(.leading, 16)
                            }
                        }
                    }
                    .background(listBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                }

                // ── 底部：按网络环境设置 ──────────────────────────────
                // 🔴 v2.7.5：用 NavigationLink push，不套 sheet ——
                // UpdateView 那边踩过：iOS 16 上 sheet 套 sheet 经常弹不出来。
                // 🔴 v2.7.6：从一行裸文字改成和上面同风格的卡片行。
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink {
                        NetworkQualityView()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(gold.opacity(0.15))
                                Image(systemName: "wifi")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(gold)
                            }
                            .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("不同网络环境下的音质")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(textPrimary)
                                Text(network.isCellular ? "当前：蜂窝网络" : "当前：非蜂窝网络")
                                    .font(.system(size: 11))
                                    .foregroundStyle(textTertiary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(listBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            }
            .padding(.bottom, 30)
        }
        .background(bg.ignoresSafeArea())
        .navigationTitle("音质")
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.27：强制深色 + 金标题，匹配用户参考图（黑底金字）。
        .preferredColorScheme(.dark)
        .kugouNavigationBarBackground(UIColor(white: 0.05, alpha: 1),
                                      titleColor: UIColor(red: 1.0, green: 0.82, blue: 0.30, alpha: 1))
    }

    // MARK: - 顶部当前选择卡片

    /// 🔴 v2.9.28：当前选中音质的单张卡片（替换原来的横向滑动特性卡）。
    private var currentQualityCard: some View {
        let q = sourceStore.quality
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(gold.opacity(0.18))
                    Image(systemName: q.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(gold)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(q.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(gold)
                        Text(q.sizeLabel)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(textSecondary)
                        if q.isAdvanced {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(gold)
                        }
                    }
                    Text(q.featureLine)
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(gold)
                    Text("当前")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(gold)
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
                        .stroke(gold, lineWidth: 1.5)
                )
        )
    }

    // MARK: - 列表行

    private func qualityRow(_ quality: MusicQuality) -> some View {
        let selected = sourceStore.quality == quality
        // 蜂窝降档开着且当前是蜂窝 → 高于高品的档位显示"已降档"提示
        let downgraded = sourceStore.cellularFallback && network.isCellular && quality != .standard
        return HStack(spacing: 12) {
            // 🔴 v2.9.28：音质名前加图标（与顶部卡片同款系统符号）
            Image(systemName: quality.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? gold : textSecondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(quality.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selected ? gold : textPrimary)
                    Text(quality.sizeLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(textTertiary)
                    if quality.isAdvanced {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(gold)
                    }
                }
                Text(downgraded ? "蜂窝网络下已自动降为高品音质" : quality.detailLine)
                    .font(.system(size: 12))
                    .foregroundStyle(downgraded ? gold : textSecondary)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(gold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

}

// MARK: - 档位展示信息

extension MusicQuality {
    /// 顶部特性卡的图标
    var icon: String {
        switch self {
        case .standard: return "waveform"
        case .higher: return "waveform.path"
        case .exHigh: return "music.note.list"
        case .lossless: return "crown.fill"
        case .hires: return "sparkles"
        }
    }

    /// 顶部特性卡的一行说明
    var featureLine: String {
        switch self {
        case .standard: return "好音质省流最佳选择"
        case .higher: return "最高 320kbps 主流清晰纯享听感"
        case .exHigh: return "最高 48kHz/24-bit CD 级无损保真"
        case .lossless: return "音源支持时自动获取母带级音源"
        case .hires: return "Hi-Res 高解析音质，细节更丰富"
        }
    }

    /// 列表里的体积标注（对应参考图里的 4.9M / 12.2M / 34.2M）
    var sizeLabel: String {
        switch self {
        case .standard: return "~4.9M/首"
        case .higher: return "~12.2M/首"
        case .exHigh: return "~34.2M/首"
        case .lossless: return "~80M/首"
        case .hires: return "~150M/首"
        }
    }

    /// 列表里的说明
    var detailLine: String {
        switch self {
        case .standard: return "好音质省流最佳选择"
        case .higher: return "最高 320kbps 主流清晰纯享听感"
        case .exHigh: return "最高 48kHz/24-bit CD 级无损保真"
        case .lossless: return "无损母带音质，需要音源支持"
        case .hires: return "Hi-Res 高解析音质，需要音源支持"
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


/// 🔴 v2.7.5：按网络环境设置（从音质页 push 进来，不套 sheet）。
/// 🔴 v2.9.27：同步改成深色主题 + 金标题。
private struct NetworkQualityView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    private let gold = Color(red: 1.0, green: 0.82, blue: 0.30)
    private let bg = Color(white: 0.05)
    private let listBg = Color(white: 0.08)

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $sourceStore.cellularFallback) {
                    Text("蜂窝网络自动降为高品音质")
                        .foregroundStyle(.white)
                }
                .tint(gold)
            } header: {
                Text("流量环境")
                    .foregroundStyle(gold)
            } footer: {
                Text(network.isCellular
                     ? "当前正在使用蜂窝网络，关闭后仍按所选音质播放（更耗流量）。"
                     : "当前不是蜂窝网络。开启后，用 4G/5G 播放时会自动降到高品音质以省流量。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .background(bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("按网络环境")
        .navigationBarTitleDisplayMode(.inline)
        .kugouNavigationBarBackground(UIColor(white: 0.05, alpha: 1),
                                      titleColor: UIColor(red: 1.0, green: 0.82, blue: 0.30, alpha: 1))
    }
}
