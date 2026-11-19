import SwiftUI

/// 🔴 2026-11-19：实验室里的播放器布局微调面板。
/// 单独拆成子视图，避免把 PlayerView 的 SwiftUI 类型检查预算再推高。
struct PlayerLayoutLabSection: View {
    @ObservedObject private var layout = PlayerLayoutSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("播放器布局微调")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 0)
                Button {
                    layout.reset()
                    Haptics.light()
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppStyle.accent)
                }
                .buttonStyle(.plain)
            }

            Text("只影响竖屏播放页；横向 X / 纵向 Y 可分别微调，数值实时保存。")
                .font(.system(size: 11))
                .foregroundStyle(AppStyle.tertiaryText)

            groupTitle("歌曲名")
            offsetRow("X", value: $layout.titleX)
            offsetRow("Y", value: $layout.titleY)

            groupTitle("歌词行")
            offsetRow("X", value: $layout.lyricX)
            offsetRow("Y", value: $layout.lyricY)

            groupTitle("动作行")
            offsetRow("X", value: $layout.actionX)
            offsetRow("Y", value: $layout.actionY)

            groupTitle("进度条")
            offsetRow("X", value: $layout.progressX)
            offsetRow("Y", value: $layout.progressY)

            groupTitle("播放控件")
            offsetRow("X", value: $layout.controlsX)
            offsetRow("Y", value: $layout.controlsY)

            HStack {
                Text("播放按钮大小")
                    .font(.system(size: 13))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 8)
                Text(String(format: "%.0f pt", Double(layout.playSize)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppStyle.secondaryText)
            }
            Slider(value: $layout.playSize, in: 44...90, step: 1)
                .accentColor(AppStyle.accent)
        }
        .padding(16)
        .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppStyle.accent)
            .padding(.top, 2)
    }

    private func offsetRow(_ axis: String, value: Binding<CGFloat>) -> some View {
        HStack(spacing: 10) {
            Text(axis)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppStyle.secondaryText)
                .frame(width: 12)
            Slider(value: value, in: -60...60, step: 1)
                .accentColor(AppStyle.accent)
            Text(String(format: "%+.0f", Double(value.wrappedValue)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppStyle.secondaryText)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
