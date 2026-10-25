import SwiftUI

/// 🔴 v2.9.0：未激活时盖在整 App 之上的授权锁屏。
/// 展示本机设备码（用来换授权码）+ 授权码输入框，校验通过即解锁，永久有效。
struct LockScreenView: View {
    @ObservedObject private var license = LicenseManager.shared

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var shake = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.34, blue: 0.78),
                         Color(red: 0.07, green: 0.13, blue: 0.33),
                         Color(red: 0.04, green: 0.07, blue: 0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 24)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.92))

                    VStack(spacing: 6) {
                        Text("AuroraMusic")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                        Text("本应用采用一机一码授权")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // 设备码卡片
                    VStack(spacing: 8) {
                        Text("本机设备码")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(license.deviceID)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = license.deviceID
                            Haptics.light()
                        } label: {
                            Label("复制设备码", systemImage: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // 授权码输入
                    VStack(spacing: 8) {
                        TextField("输入授权码", text: $input)
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            .submitLabel(.go)
                            .focused($focused)
                            .padding(14)
                            .background(.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onSubmit(attempt)
                            .modifier(ShakeModifier(shake: shake))

                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.5))
                        }
                    }

                    Button(action: attempt) {
                        Text("激活")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [Color(red: 0.29, green: 0.55, blue: 0.98),
                                                        Color(red: 0.20, green: 0.42, blue: 0.92)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text("把上方设备码发给作者，换取对应的授权码。\n一个设备码对应一个授权码，换手机需重新获取。")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .onTapGesture { focused = false }
    }

    private func attempt() {
        let code = input
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if license.activate(code: code) {
            errorMessage = nil
        } else {
            errorMessage = "授权码无效，请核对设备码后重新获取"
            Haptics.light()
            withAnimation(.default) { shake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { shake = false }
        }
    }
}

/// 校验失败抖一下
private struct ShakeModifier: ViewModifier {
    let shake: Bool
    func body(content: Content) -> some View {
        content.offset(x: shake ? -6 : 0)
            .animation(shake ? Animation.default.repeatCount(3, autoreverses: true).speed(6) : .default,
                       value: shake)
    }
}
