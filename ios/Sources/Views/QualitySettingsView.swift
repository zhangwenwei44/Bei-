import SwiftUI

/// 🔴 v2.7.4：音质设置页（版式参考酷狗 App 的「音质」页）。
///
/// 版式对齐用户给的参考图：
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── 顶部：横向特性卡 ────────────────────────────────
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(MusicQuality.allCases) { quality in
                            featureCard(quality)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                // ── 中部：高级音质列表 ───────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("高级音质")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
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
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                }

                // ── 底部：按网络环境设置 ──────────────────────────────
                Button {
                    networkSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("设置不同网络环境下的播放音质")
                            .font(.system(size: 14))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(AppStyle.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 30)
        }
        .background(AppStyle.background)
        .navigationTitle("音质")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $networkSheet) {
            networkQualitySheet
        }
    }

    @State private var networkSheet = false

    // MARK: - 顶部特性卡

    private func featureCard(_ quality: MusicQuality) -> some View {
        let selected = sourceStore.quality == quality
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: quality.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.tertiaryText)
                Text(quality.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppStyle.primaryText)
            }
            Text(quality.featureLine)
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 150, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? AppStyle.accent.opacity(0.9) : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - 列表行

    private func qualityRow(_ quality: MusicQuality) -> some View {
        let selected = sourceStore.quality == quality
        // 蜂窝降档开着且当前是蜂窝 → 高于高品的档位显示"已降档"提示
        let downgraded = sourceStore.cellularFallback && network.isCellular && quality != .standard
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(quality.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppStyle.primaryText)
                    Text(quality.sizeLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AppStyle.tertiaryText)
                    if quality.isAdvanced {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppStyle.accent)
                    }
                }
                Text(downgraded ? "蜂窝网络下已自动降为高品音质" : quality.detailLine)
                    .font(.system(size: 12))
                    .foregroundStyle(downgraded ? AppStyle.accent : AppStyle.secondaryText)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppStyle.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - 按网络环境

    private var networkQualitySheet: some View {
        CompatNavigationStack {
            Form {
                Section {
                    Toggle(isOn: $sourceStore.cellularFallback) {
                        Text("蜂窝网络自动降为高品音质")
                    }
                    .tint(AppStyle.accent)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { networkSheet = false }
                }
            }
        }
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
