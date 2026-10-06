import SwiftUI

/// 首次启动免责声明。必须手输「我已了解并同意继续使用」才能点同意继续。
/// UserDefaults key: aurora.disclaimer.accepted
struct DisclaimerView: View {
    private let agreedKey = "aurora.disclaimer.accepted"
    private let requiredPhrase = "我已了解并同意继续使用"

    @State private var input = ""
    @State private var showingDetails = false

    private var isMatch: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == requiredPhrase
    }

    var body: some View {
        ZStack {
            AppStyle.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // 图标 + 标题
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(AppStyle.accent)
                        .padding(.top, 32)

                    Text("免责声明")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(AppStyle.primaryText)

                    Text("请在使用 Aurora Music 前仔细阅读以下内容")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.secondaryText)
                        .multilineTextAlignment(.center)

                    // 声明卡片
                    VStack(alignment: .leading, spacing: 16) {
                        bullet("Aurora Music 仅用于个人学习与技术交流，不提供任何音乐资源的存储、上传或分发服务。")
                        bullet("所有歌曲播放均来自第三方公开接口，本 App 不缓存、不复制、不上传任何音源文件。")
                        bullet("用户对自己的使用行为承担全部责任，如有版权争议请联系相关音源提供方。")
                        bullet("本软件按「现状」提供，开发者不对任何因使用本 App 产生的直接或间接损失承担责任。")
                        bullet("继续使用即表示你已阅读、理解并同意以上全部内容。")
                    }
                    .padding(20)
                    .background(AppStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)

                    // 输入区
                    VStack(spacing: 12) {
                        Text("请输入以下文字以确认：")
                            .font(.system(size: 14))
                            .foregroundStyle(AppStyle.secondaryText)

                        HStack(spacing: 8) {
                            TextField("请输入确认文字", text: $input)
                                .font(.system(size: 15))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(AppStyle.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isMatch ? AppStyle.accent : AppStyle.secondaryText.opacity(0.25),
                                                lineWidth: isMatch ? 2 : 1)
                                )
                                .foregroundStyle(AppStyle.primaryText)
                                .submitLabel(.done)

                            Button {
                                UIPasteboard.general.string = requiredPhrase
                                input = requiredPhrase
                                Haptics.light()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(AppStyle.accent)
                                    .frame(width: 44, height: 44)
                                    .background(AppStyle.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("一键填入")
                        }

                        // 提示
                        if !input.isEmpty && !isMatch {
                            Text("请输入完整的确认文字")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // 一键填入按钮（备用）
                        if !isMatch {
                            Button {
                                input = requiredPhrase
                                Haptics.light()
                            } label: {
                                Text("一键填入：\(requiredPhrase)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppStyle.accent)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Spacer(minLength: 40)

                    // 同意按钮
                    Button {
                        UserDefaults.standard.set(true, forKey: agreedKey)
                        Haptics.soft()
                    } label: {
                        Text("同意并继续")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isMatch
                                          ? LinearGradient(colors: [AppStyle.accent, AppStyle.like],
                                                           startPoint: .leading, endPoint: .trailing)
                                          : LinearGradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.4)],
                                                           startPoint: .leading, endPoint: .trailing))
                            )
                            .foregroundStyle(.white)
                            .opacity(isMatch ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isMatch)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(AppStyle.accent)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(AppStyle.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    DisclaimerView()
}
