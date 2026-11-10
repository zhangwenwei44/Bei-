import SwiftUI

// MARK: - 骨架屏（2026-11-10）
//
// 🔴 用户要求：内容加载时不再显示转圈菊花，改成
//    ① 先按【真内容的样子】摆出灰色占位块（方形封面 + 歌名条 + 歌手条 …）；
//    ② 再在【整个骨架】上盖一层半透明的光，从左往右匀速平移扫过，一直重复。
// 🔴 iOS 15：LinearGradient 没有 stops / locations API，用等距色标模拟柔光带；
//    动画用 `.animation(.linear(duration:).repeatForever(autoreverses: false), value:)`，
//    autoreverses:false 保证方向单一、匀速、每轮从左侧重新开始，不来回摆。
// 🔴 光带用「骨架自身」做 mask：只有灰色块被照亮，白色背景不会一起发白；
//    而且光带是【一条贯穿整个骨架】的，不是每个块各闪一次，所有块共享同一相位。
// 🔴 所有尺寸都锁死，占位块不参与父布局伸缩；allowsHitTesting(false) 不抢手势。
//    XcodeGen `sources: - path: Sources` 递归收录本文件，无需改工程配置。

private enum SkeletonPalette {
    /// 固定 RGB：不用 dynamic 色，避免主题切换时骨架忽明忽暗。
    static let block = Color(red: 0.886, green: 0.898, blue: 0.918)
    static let soft = Color(red: 0.933, green: 0.941, blue: 0.953)
    static let text = Color(red: 0.855, green: 0.867, blue: 0.890)
}

/// 一块灰色占位。默认固定宽高，不撑大父布局。
struct SkeletonBlock: View {
    let width: CGFloat
    let height: CGFloat
    var corner: CGFloat = 5
    var color: Color = SkeletonPalette.block

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }
}

/// 扫光容器：把任意「灰色占位块组合」包起来，盖一条贯穿的半透明光带。
/// 🔴 `content()` 会被调用两次（显示一次、mask 一次），因此骨架内容必须是纯静态视图，
///    不要在里面放 @State / 网络请求 / 动画驱动。
struct SkeletonShimmer<Content: View>: View {
    private let content: () -> Content
    @State private var sweeping = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .overlay(
                GeometryReader { geo in
                    let band = max(geo.size.width * 0.42, 80)
                    LinearGradient(colors: [Color.white.opacity(0),
                                            Color.white.opacity(0.46),
                                            Color.white.opacity(0.46),
                                            Color.white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band, height: geo.size.height)
                        // 起点 -band（完全在左外侧）→ 终点容器右边界（光带完全扫出）。
                        .offset(x: sweeping ? geo.size.width : -band)
                        .animation(.linear(duration: 1.4).repeatForever(autoreverses: false),
                                   value: sweeping)
                }
                .mask(content())
                .allowsHitTesting(false)
            )
            .onAppear { sweeping = true }
    }
}

/// 横滑歌曲 / 歌单卡骨架：对应 `slideSongCard` 的真实版式
/// （108×108 圆角封面 + 13pt 歌名条 + 11pt 歌手条），一行摆 4 张。
/// 用于「新歌推荐 / 每日推荐 / 猜你喜欢 / 经典推荐 / DJ推荐 / 歌单推荐 / 热门歌手专辑」。
struct SlideCardsSkeleton: View {
    var cardSize: CGFloat = 108
    var count: Int = 4

    var body: some View {
        SkeletonShimmer {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: cardSize, height: cardSize, corner: 10)
                        SkeletonBlock(width: cardSize * 0.82, height: 13, corner: 4,
                                      color: SkeletonPalette.text)
                        SkeletonBlock(width: cardSize * 0.56, height: 11, corner: 4,
                                      color: SkeletonPalette.soft)
                    }
                    .frame(width: cardSize, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 108 + 6 + 13 + 6 + 11 + 上下 4 = 148，与真实卡片区等高，加载完不会跳版。
        .frame(height: cardSize + 40, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// 纵向列表骨架：对应歌曲 / 歌手行的真实版式（48×48 圆角头像 + 两行文字）。
struct ListRowsSkeleton: View {
    var rows: Int = 6

    var body: some View {
        SkeletonShimmer {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 48, height: 48, corner: 8)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 148, height: 13, corner: 4,
                                          color: SkeletonPalette.text)
                            SkeletonBlock(width: 92, height: 11, corner: 4,
                                          color: SkeletonPalette.soft)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }
}

/// 首页首屏骨架：banner + 5 个圆形功能入口 + 两个板块标题 + 一行横滑卡片，
/// 完全按推荐 Tab 的真实结构摆位。替换原来的 `LoadingRow()`（菊花 + 「加载中…」）。
struct FeedSkeleton: View {
    var body: some View {
        SkeletonShimmer {
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBlock(width: 343, height: 150, corner: 14)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(spacing: 8) {
                            SkeletonBlock(width: 52, height: 52, corner: 14)
                            SkeletonBlock(width: 44, height: 10, corner: 4,
                                          color: SkeletonPalette.soft)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)

                ForEach(0..<2, id: \.self) { _ in
                    SkeletonBlock(width: 92, height: 18, corner: 5,
                                  color: SkeletonPalette.text)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                SkeletonBlock(width: 108, height: 108, corner: 10)
                                SkeletonBlock(width: 88, height: 13, corner: 4,
                                              color: SkeletonPalette.text)
                                SkeletonBlock(width: 60, height: 11, corner: 4,
                                              color: SkeletonPalette.soft)
                            }
                            .frame(width: 108, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 560)
        .allowsHitTesting(false)
    }
}

/// 底部「加载更多」的小骨架：两小段灰条，替代分页触发处的转圈菊花。
struct SkeletonInlineRow: View {
    var body: some View {
        SkeletonShimmer {
            HStack(spacing: 8) {
                SkeletonBlock(width: 62, height: 11, corner: 4,
                              color: SkeletonPalette.text)
                SkeletonBlock(width: 40, height: 11, corner: 4,
                              color: SkeletonPalette.soft)
            }
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .allowsHitTesting(false)
    }
}
