import SwiftUI

/// 🔴 2026-11-21：音质 / 音源 的「贴合内容高度」底部面板。
///
/// 背景：iOS 15 的 `.sheet` 容器恒为整屏，内部视图即使设了 0.55/0.60 屏高，
/// 也会在容器里居中/顶对齐 → 上下大片留白（用户连续两轮反馈的问题）。
/// 这里改用项目已有的自定义 overlay 模式（同主题选择器），面板高度 = 内容高度，
/// 只有一层圆角卡片 + 半透明遮罩，点遮罩 / 点横条 / 下滑都能关闭。
///
/// 深浅色：面板背景用 `AppStyle.surface`（dynamic），深色模式自动变深色卡片。
struct CompactPanelOverlay<Content: View>: View {
    let onDismiss: () -> Void
    let content: Content

    /// 底部安全区高度（home indicator），从 key window 读，兜底 34pt。
    private static var bottomInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let win = ws.windows.first(where: { $0.isKeyWindow }) {
                return max(8, win.safeAreaInsets.bottom)
            }
        }
        return 34
    }

    init(onDismiss: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 半透明遮罩：点一下关闭（Color.clear 不参与命中，用 contentShape 兜住）
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            // 内容卡片：高度完全由内容决定，只圆上方两角、底部贴屏幕底
            VStack(spacing: 0) {
                content
                // home indicator 安全区留白（overlay 贴在窗口底，需自己留）
                Color.clear.frame(height: Self.bottomInset)
            }
            .frame(maxWidth: .infinity)
            .background(AppStyle.surface)
            .clipShape(CompactPanelTopCorners(radius: 20))
            .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 只圆上方两角（SwiftUI 无内置部分圆角，用 Shape 精确控制）。
private struct CompactPanelTopCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: radius))
        p.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: radius),
                       control: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}
