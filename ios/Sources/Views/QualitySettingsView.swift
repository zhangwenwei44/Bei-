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
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("音质选择")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppStyle.primaryText)
                        Spacer(minLength: 8)
                        Text("当前：\(sourceStore.quality.title)")
                            .font(.system(size: 12))
                            .foregroundStyle(AppStyle.tertiaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    // 🔴 v2.7.6：卡片必须等高 —— 之前只写死 width、高度由文案行数决定，
                    // 说明文字一行 / 两行的卡就变成「一大一小」（用户反馈）。
                    // 现在整张卡写死 152×130，文案再多也不影响外框尺寸。
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(MusicQuality.allCases) { quality in
                                featureCard(quality)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)   // 给选中描边留位置，避免被裁掉
                    }
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
                        Spacer(minLength: 8)
                        Text("按音源实际支持的档位播放")
                            .font(.system(size: 11))
                            .foregroundStyle(AppStyle.tertiaryText)
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
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                                    .fill(AppStyle.accent.opacity(0.14))
                                Image(systemName: "wifi")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppStyle.accent)
                            }
                            .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("不同网络环境下的音质")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AppStyle.primaryText)
                                Text(network.isCellular ? "当前：蜂窝网络" : "当前：非蜂窝网络")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.tertiaryText)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppStyle.tertiaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                    Text("说明：实际播放音质取决于音源本身是否提供该档位，选择更高档位不会凭空提升码率。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppStyle.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 30)
        }
        .background(AppStyle.background)
        .navigationTitle("音质")
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
        .kugouNavigationBarBackground()
    }

    // MARK: - 顶部特性卡

    private func featureCard(_ quality: MusicQuality) -> some View {
        let selected = sourceStore.quality == quality
        return Button {
            sourceStore.quality = quality
            Haptics.light()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? AppStyle.accent
                                  : AppStyle.accent.opacity(0.14))
                        Image(systemName: quality.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? AppStyle.onAccent : AppStyle.accent)
                    }
                    .frame(width: 24, height: 24)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AppStyle.accent)
                    }
                }
                .padding(.bottom, 9)

                Text(quality.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? AppStyle.accent : AppStyle.primaryText)
                    .lineLimit(1)

                Text(quality.sizeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .padding(.top, 2)

                Text(quality.featureLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 5)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 11)
            // 🔴 写死宽高 —— 卡片等高（之前只有 width 写死，说明文字行数不同就一大一小）
            .frame(width: 152, height: 130, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppStyle.surface)
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [AppStyle.accent.opacity(0.20),
                                                          AppStyle.accent.opacity(0.04)],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? AppStyle.accent : AppStyle.stroke,
                            lineWidth: selected ? 1.5 : 0.6)
            )
        }
        .buttonStyle(.plain)
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
private struct NetworkQualityView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @ObservedObject private var network = NetworkStatus.shared

    var body: some View {
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
        // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
        .kugouNavigationBarBackground()
    }
}
