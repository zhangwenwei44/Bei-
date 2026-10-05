import SwiftUI

/// 登录/注册页 — 首次启动未登录时显示，或从设置页退出登录后显示。
struct LoginView: View {
    @EnvironmentObject private var auth: AuthService
    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Mode { case login, register }
    private enum Field { case username, password, confirm }

    var body: some View {
        VStack(spacing: 32) {
            // Logo + 标题
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(AppStyle.accent)
                    .frame(width: 96, height: 96)
                    .background(AppStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
                Text("Aurora Music")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
            }
            .padding(.top, 60)

            // 模式切换
            Picker("", selection: $mode) {
                Text("登录").tag(Mode.login)
                Text("注册").tag(Mode.register)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            .onChange(of: mode) { _ in
                errorMessage = nil
                password = ""
                confirmPassword = ""
            }

            // 表单
            VStack(spacing: 14) {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .padding()
                    .background(AppStyle.tertiaryText.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                SecureField("密码", text: $password)
                    .focused($focus, equals: .password)
                    .padding()
                    .background(AppStyle.tertiaryText.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                if mode == .register {
                    SecureField("再输一遍密码", text: $confirmPassword)
                        .focused($focus, equals: .confirm)
                        .padding()
                        .background(AppStyle.tertiaryText.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 32)

            // 错误提示
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }

            // 主按钮
            Button {
                submit()
            } label: {
                Text(mode == .login ? "登录" : "注册")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(AppStyle.onAccent)
            }
            .padding(.horizontal, 32)
            .disabled(!canSubmit)

            // 游客入口
            Button {
                auth.logout() // 确保是游客模式
            } label: {
                Text("先看看，用游客模式")
                    .font(.system(size: 14))
                    .foregroundStyle(AppStyle.tertiaryText)
            }

            Spacer()
        }
        .background(AppStyle.background)
    }

    private var canSubmit: Bool {
        let u = username.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !password.isEmpty else { return false }
        if mode == .register {
            guard password.count >= 4,
                  password == confirmPassword else { return false }
        }
        return true
    }

    private func submit() {
        errorMessage = nil
        do {
            switch mode {
            case .login:
                try auth.login(username: username, password: password)
            case .register:
                try auth.register(username: username, password: password)
            }
        } catch let err as AuthError {
            errorMessage = err.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
