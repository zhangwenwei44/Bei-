import SwiftUI

// MARK: - iOS 15 兼容层
// 原 deploymentTarget=16.0，iOS 15 上 NavigationStack 类不存在 → dyld crash。
// 方案：所有 iOS 16 API 用 if #available(iOS 16.0, *) { ... } else { self } 包裹。

// MARK: NavigationStack ↔ NavigationView

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

// MARK: - 简单兼容扩展（内部 if #available 包装 iOS 16 API）

extension View {
    @ViewBuilder
    func compatScrollContentBackground(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) { scrollContentBackground(visibility) } else { self }
    }

    @ViewBuilder
    func compatToolbarHidden() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else { self }
    }
}

// MARK: - FlowLayout / Layout protocol

@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

/// iOS 15 FlowChips fallback（手动 HStack 换行）
struct LegacyFlowChips: View {
    let items: [String]
    var action: (String) -> Void
    var spacing: CGFloat = 8

    var body: some View {
        let screenW = UIScreen.main.bounds.width - 32
        var currentW: CGFloat = 0
        var currentRow: [String] = []
        var rows: [[String]] = []
        for item in items {
            let estW = CGFloat(item.count) * 7 + 24
            if currentW + estW > screenW && !currentRow.isEmpty {
                rows.append(currentRow); currentRow = []; currentW = 0
            }
            currentRow.append(item); currentW += estW + spacing
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
