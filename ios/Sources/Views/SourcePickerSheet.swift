import SwiftUI

/// 2026-11-20：播放器动作行「音源」按钮弹出的半屏音源面板。
///
/// 需求：点击弹出弹窗显示音源，可对音源开关、调整顺序。
/// 复用 `SourceStore.setEnabled` / `reorder`，数据与实际解析优先级完全一致；
/// 只做「开关 + 拖动排序 + 健康状态」，不暴露编辑/导入/删除等高级入口（那些留在设置页）。
/// 🔴 2026-11-21：嵌在 `CompactPanelOverlay` 里，横条/背景/圆角由外层统一提供；
///    列表高度按音源行数自适应 —— 修复旧版固定 0.55 屏高「上下大片留白」。
///    深色模式跟随 App 主题（去掉强制浅色）。
struct SourcePickerSheet: View {
    @ObservedObject private var store = SourceStore.shared
    @ObservedObject private var health = SourceHealth.shared
    @Environment(\.editMode) private var editMode
    let onDismiss: () -> Void

    private var isEditing: Bool {
        guard let mode = editMode?.wrappedValue else { return false }
        return mode == .active
    }

    /// 每行高度（含分隔线），用于让 List 高度贴合内容而非撑满屏幕。
    private let rowHeight: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            // 顶部拖拽指示条（点击也能关闭）
            Button { onDismiss() } label: {
                Capsule()
                    .fill(AppStyle.stroke)
                    .frame(width: 38, height: 5)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)

            HStack {
                Text("音源")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 8)
                if !store.sources.isEmpty {
                    Button {
                        withAnimation {
                            editMode?.wrappedValue = isEditing ? .inactive : .active
                        }
                    } label: {
                        Text(isEditing ? "完成" : "排序")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppStyle.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            List {
                if store.sources.isEmpty {
                    Text("还没有音源，请到设置页添加")
                        .font(.system(size: 13))
                        .foregroundStyle(AppStyle.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else {
                    ForEach(store.sources) { source in
                        pickerRow(source)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(AppStyle.stroke)
                    }
                    .onMove { offsets, destination in
                        var list = store.sources
                        list.move(fromOffsets: offsets, toOffset: destination)
                        store.reorder(list)
                    }
                }
            }
            .listStyle(.plain)
            .compatScrollContentBackground(.hidden)
            // 🔴 高度贴合内容：行数 × 行高（最多给 6 行，再多交给面板整体高度）
            .frame(height: min(CGFloat(max(1, store.sources.count)) * rowHeight + 8, rowHeight * 6 + 8))

            Text("从上到下为解析优先级，排在前面的先尝试。绿点＝可用，红点＝无用。")
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        // 🔴 2026-11-21：去掉固定 0.55 屏高，高度由内容决定；背景透明，交给外层面板按深浅模式绘制。
        .background(Color.clear)
    }

    @ViewBuilder
    private func pickerRow(_ source: ThirdPartySource) -> some View {
        HStack(spacing: 12) {
            healthDot(for: source.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.isBundled ? "默认音源" : source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(detail(for: source))
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in store.setEnabled(!source.enabled, id: source.id) }
            ))
            .labelsHidden()
            .tint(AppStyle.accent)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func healthDot(for id: String) -> some View {
        switch health.status(for: id) {
        case .ok:
            Circle().fill(Color.green).frame(width: 9, height: 9)
        case .bad:
            Circle().fill(Color.red).frame(width: 9, height: 9)
        case .checking:
            ProgressView().scaleEffect(0.6).frame(width: 9, height: 9).tint(AppStyle.tertiaryText)
        case .unknown:
            Color.clear.frame(width: 9, height: 9)
        }
    }

    private func detail(for source: ThirdPartySource) -> String {
        let support = source.supportedQualityLabels
        let supportText = support.isEmpty ? "默认 \(source.quality)" : "支持 \(support.joined(separator: "·"))"
        if source.isScript { return "JS 脚本 · \(supportText)" }
        let host = URL(string: source.template)?.host ?? "地址无效"
        return "\(host) · \(supportText)"
    }
}
