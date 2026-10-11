import SwiftUI

// MARK: - iOS 15 兼容层
// 原 deploymentTarget=16.0，iOS 15 上 NavigationStack 等类不存在 → dyld crash 闪退。
// 本文件 + 项目内批量 #available 让二进制在 iOS 15 runtime 也能加载。

// MARK: NavigationStack ↔ NavigationView

/// iOS 16+ 用 NavigationStack，iOS 15 fallback 到 NavigationView
struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

// MARK: - iOS 16 API 兼容扩展

extension View {
    @ViewBuilder
    func compatScrollContentBackground(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(visibility)
        } else { self }
    }

    @ViewBuilder
    func compatToolbarHidden() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else { self }
    }

    /// presentationDetents iOS 16+，iOS 15 忽略（sheet 全屏展示）
    @ViewBuilder
    func compatPresentationDetents(_ detents: [PresentationDetent]) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents(detents)
        } else { self }
    }

    /// presentationDragIndicator iOS 16+，iOS 15 忽略
    @ViewBuilder
    func compatPresentationDragIndicator(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(visibility)
        } else { self }
    }

    /// scrollIndicators iOS 16+，iOS 15 忽略
    @ViewBuilder
    func compatScrollIndicators(_ visibility: ScrollIndicatorVisibility) -> some View {
        if #available(iOS 16.0, *) {
            scrollIndicators(visibility)
        } else { self }
    }

    /// ShareLink iOS 16+，iOS 15 fallback 到 UIActivityViewController
    @ViewBuilder
    static func compatShareLink(item: URL, subject: String, label: String) -> some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: item, subject: Text(subject), label: { Text(label) })
        } else {
            Button {
                guard let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first?.windows.first(where: { $0.isKeyWindow }) else { return }
                let vc = UIActivityViewController(activityItems: [item], applicationActivities: nil)
                vc.popoverPresentationController?.sourceView = window
                vc.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                window.rootViewController?.present(vc, animated: true)
            } label: { Text(label) }
        }
    }
}

// MARK: - FlowLayout / Layout protocol iOS 15 fallback

/// iOS 15 上没有 Layout 协议，FlowLayout 用 ZStack + offset 简单实现
/// iOS 16+ 直接用 Layout 协议的 FlowLayout
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return Self.calculateSize(subviews: subviews, width: width, spacing: spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        Self.place(subviews: subviews, bounds: bounds, spacing: spacing)
    }

    static func calculateSize(subviews: Subviews, width: CGFloat, spacing: CGFloat) -> CGSize {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    static func place(subviews: Subviews, bounds: CGRect, spacing: CGFloat) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

/// iOS 15 简单 FlowChips（VStack + HStack 手排）
@available(iOS, deprecated: 16.0, message: "iOS 16+ 用 Layout 协议版")
struct LegacyFlowChips: View {
    let items: [String]
    var action: (String) -> Void
    var spacing: CGFloat = 8
    let screenWidth = UIScreen.main.bounds.width - 32

    var body: some View {
        var currentRow: [String] = []
        var rows: [[String]] = []
        var currentWidth: CGFloat = 0
        let chipH: CGFloat = 30
        let chipHInset: CGFloat = 14  // padding(.horizontal, 12) * 2

        for item in items {
            let estimate = CGFloat(item.count) * 7 + chipHInset
            if currentWidth + estimate > screenWidth && !currentRow.isEmpty {
                rows.append(currentRow); currentRow = []; currentWidth = 0
            }
            currentRow.append(item); currentWidth += estimate + spacing
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { item in
                        Button { Haptics.light(); action(item) } label: {
                            Text(item).font(.system(size: 13)).foregroundStyle(AppStyle.primaryText)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(AppStyle.surface, in: Capsule())
                                .overlay(Capsule().stroke(AppStyle.stroke, lineWidth: 0.5))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

