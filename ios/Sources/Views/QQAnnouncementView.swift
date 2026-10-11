import SwiftUI

/// 启动公告：QQ 群邀请 —— 可关闭（@AppStorage 记住用户选择）
struct QQAnnouncementView: View {
    @Environment(\.dismiss) private var dismiss
    static let groupNumber = "1124217335"

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 0.95),
                                     Color(red: 0.10, green: 0.25, blue: 0.60)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // 🔔 图标
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)

                // 标题
                Text("AuroraMusic 开发者交流群")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                // 描述
                VStack(spacing: 6) {
                    Text("加入官方 QQ 群，一起让 AuroraMusic 变得更好！")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)

                    bullet("Bug 反馈与问题排查")
                    bullet("新功能需求与改进建议")
                    bullet("音源更新与技术交流")
                    bullet("开发进度与版本预告")
                }
                .padding(.horizontal, 12)

                // QQ 群号大字
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.95))
                    VStack(spacing: 4) {
                        Text("QQ 群号")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(Self.groupNumber)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.80))
                        Button {
                            UIPasteboard.general.string = Self.groupNumber
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("一键复制群号")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.80))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color(red: 0.10, green: 0.35, blue: 0.80).opacity(0.12),
                                        in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .padding(.horizontal, 24)

                Spacer(minLength: 0)

                // 知道了
                Button {
                    dismiss()
                } label: {
                    Text("知道了，去体验 ☺")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.80))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 28))
                }

                Button {
                    dismiss()
                } label: {
                    Text("不再显示此公告")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .onTapGesture {
                    UserDefaults.standard.set(true, forKey: "aurora.qqAnnouncement.dismissed")
                    dismiss()
                }
            }
            .padding(28)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("✦").foregroundStyle(.white.opacity(0.75))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
