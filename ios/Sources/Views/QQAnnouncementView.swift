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

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // 🔔 图标 + 标题
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.18))
                            .frame(width: 72, height: 72)
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.white)
                    }

                    Text("加入 AuroraMusic 开发者交流群")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("一起打造更好的音乐 App 🎵")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.bottom, 24)

                // ✦ Bullet 列表：左对齐严格等宽
                VStack(alignment: .leading, spacing: 10) {
                    bulletRow(icon: "ant.fill", text: "Bug 反馈与问题排查")
                    bulletRow(icon: "sparkles", text: "新功能需求与改进建议")
                    bulletRow(icon: "network", text: "音源更新与技术交流")
                    bulletRow(icon: "newspaper", text: "开发进度与版本预告")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

                // 群号卡片
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.white.opacity(0.97))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    VStack(spacing: 6) {
                        Text("QQ 群号")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(Self.groupNumber)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
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
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color(red: 0.10, green: 0.35, blue: 0.80).opacity(0.12),
                                        in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .padding(.horizontal, 28)

                Spacer(minLength: 0)

                // 按钮组
                VStack(spacing: 14) {
                    Button {
                        dismiss()
                    } label: {
                        Text("知道了，去体验 ☺")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(red: 0.10, green: 0.35, blue: 0.80))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(.white, in: RoundedRectangle(cornerRadius: 28))
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    }

                    Button {
                        UserDefaults.standard.set(true, forKey: "aurora.qqAnnouncement.dismissed")
                        dismiss()
                    } label: {
                        Text("不再显示此公告")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
            .padding(.top, 20)
        }
    }

    private func bulletRow(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 18)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.93))
        }
    }
}
