import SwiftUI

/// 首次启动免责声明。必须手输「我已了解并同意继续使用」才能点同意继续。
/// UserDefaults key: aurora.disclaimer.accepted
struct DisclaimerView: View {
    private let agreedKey = "aurora.disclaimer.accepted"
    private let requiredPhrase = "我已了解并同意继续使用"

    @State private var input = ""

    private var isMatch: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == requiredPhrase
    }

    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient(colors: [
                Color.black,
                Color(red: 0.12, green: 0.06, blue: 0.18),
                Color(red: 0.06, green: 0.1, blue: 0.2)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // ============ Hero 区 ============
                    heroSection

                    // ============ 声明卡片 ============
                    VStack(alignment: .leading, spacing: 14) {
                        Text("请在使用 Aurora Music 前仔细阅读")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        disclaimerRow(icon: "music.note",
                                      tint: Color(red: 0.4, green: 0.7, blue: 1.0),
                                      text: "Aurora Music 仅用于个人学习与技术交流，不提供任何音乐资源的存储、上传或分发服务。")
                        disclaimerRow(icon: "link",
                                      tint: Color(red: 1.0, green: 0.6, blue: 0.3),
                                      text: "所有歌曲播放均来自第三方公开接口，本 App 不缓存、不复制、不上传任何音源文件。")
                        disclaimerRow(icon: "person.crop.circle.badge.exclamationmark",
                                      tint: Color(red: 1.0, green: 0.4, blue: 0.5),
                                      text: "用户对自己的使用行为承担全部责任，如有版权争议请联系相关音源提供方。")
                        disclaimerRow(icon: "exclamationmark.triangle",
                                      tint: Color(red: 1.0, green: 0.85, blue: 0.3),
                                      text: "本软件按「现状」提供，开发者不对任何因使用本 App 产生的直接或间接损失承担责任。")
                        disclaimerRow(icon: "checkmark.seal.fill",
                                      tint: Color(red: 0.4, green: 0.9, blue: 0.6),
                                      text: "继续使用即表示你已阅读、理解并同意以上全部内容。")
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 28)

                    // ============ 输入确认区 ============
                    VStack(spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("请输入以下文字以确认你已阅读")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.55))
                        }

                        HStack(spacing: 10) {
                            TextField("输入确认文字", text: $input)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .tint(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(isMatch ? Color(red: 0.4, green: 0.9, blue: 0.6) : .white.opacity(0.15),
                                                lineWidth: isMatch ? 2 : 1)
                                )
                                .submitLabel(.done)

                            Button {
                                UIPasteboard.general.string = requiredPhrase
                                input = requiredPhrase
                                Haptics.light()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("一键填入")
                        }

                        if !input.isEmpty && !isMatch {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 12))
                                Text("请输入完整的确认文字")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                    // ============ 同意按钮 ============
                    Button {
                        UserDefaults.standard.set(true, forKey: agreedKey)
                        Haptics.soft()
                    } label: {
                        HStack(spacing: 8) {
                            if isMatch {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            Text("同意并继续")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isMatch
                                      ? LinearGradient(colors: [
                                          Color(red: 0.4, green: 0.7, blue: 1.0),
                                          Color(red: 0.8, green: 0.4, blue: 1.0)
                                      ], startPoint: .leading, endPoint: .trailing)
                                      : LinearGradient(colors: [
                                          Color.white.opacity(0.1),
                                          Color.white.opacity(0.1)
                                      ], startPoint: .leading, endPoint: .trailing))
                        )
                        .foregroundStyle(isMatch ? .white : .white.opacity(0.4))
                        .opacity(isMatch ? 1 : 0.7)
                        .shadow(color: isMatch ? Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.4) : .clear,
                                radius: 20, y: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isMatch)
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: - Subviews

    private var heroSection: some View {
        VStack(spacing: 18) {
            ZStack {
                // 外圈光晕
                Circle()
                    .fill(
                        RadialGradient(colors: [
                            Color(red: 0.5, green: 0.3, blue: 1.0).opacity(0.3),
                            Color(red: 0.5, green: 0.3, blue: 1.0).opacity(0.0)
                        ], center: .center, startRadius: 0, endRadius: 80)
                    )
                    .frame(width: 160, height: 160)

                // 黑胶图标
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [.black, Color(red: 0.15, green: 0.15, blue: 0.2)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 100, height: 100)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )

                    Circle()
                        .fill(Color(red: 0.8, green: 0.4, blue: 1.0))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.3), lineWidth: 1)
                        )

                    Circle()
                        .fill(.black)
                        .frame(width: 8, height: 8)
                }

                // 旋转装饰
                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(0.03))
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
            }
            .padding(.top, 48)

            VStack(spacing: 8) {
                Text("Aurora Music")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("极光音乐 · 由你掌控")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private func disclaimerRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)

            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }
}

#Preview {
    DisclaimerView()
}
