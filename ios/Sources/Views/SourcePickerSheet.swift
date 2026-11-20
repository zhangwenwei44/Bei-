import SwiftUI

/// 2026-11-20：播放器动作行「音源」按钮弹出的半屏音源面板。
///
/// 需求：点击弹出弹窗显示音源，可对音源开关。
/// 复用 `SourceStore.setEnabled` / `reorder`，数据与实际解析优先级完全一致。
/// 🔴 2026-11-21：嵌在 `CompactPanelOverlay` 里，横条/背景/圆角由外层统一提供；
///    列表高度按音源行数自适应。深色模式跟随 App 主题（去掉强制浅色）。
/// 🔴 2026-11-21（二）：右上角「排序」改成「检测音源」按钮（重新体检全部音源），
///    底部优先级说明按用户要求移除；不再提供拖动排序入口。
struct SourcePickerSheet: View {
    @ObservedObject private var store = SourceStore.shared
    @ObservedObject private var health = SourceHealth.shared
    @State private var isChecking = false
    let onDismiss: () -> Void

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
                        guard !isChecking else { return }
                        isChecking = true
                        Task {
                            await SourceHealth.shared.checkAll()
                            await MainActor.run { isChecking = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isChecking {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 13, height: 13)
                            }
                            Text(isChecking ? "检测中" : "检测音源")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(AppStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)
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
                }
            }
            .listStyle(.plain)
            .compatScrollContentBackground(.hidden)
            // 🔴 高度贴合内容：行数 × 行高（最多给 6 行，再多交给面板整体高度）
            .frame(height: min(CGFloat(max(1, store.sources.count)) * rowHeight + 8, rowHeight * 6 + 8))
        }
        // 🔴 背景透明，交给外层面板按深浅模式绘制。
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
