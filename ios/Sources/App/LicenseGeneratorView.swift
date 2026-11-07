import SwiftUI

// MARK: - 签发记录

struct LicenseRecord: Identifiable, Codable {
    let id: UUID
    let deviceID: String
    let code: String
    var note: String
    let createdAt: Date
}

/// 已签发的授权码记录（存本地 UserDefaults，可导出 CSV 备查/补发）
final class LicenseRecordStore: ObservableObject {
    static let shared = LicenseRecordStore()

    @Published private(set) var records: [LicenseRecord] = []

    private let key = "aurora.license.records"

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([LicenseRecord].self, from: data) else { return }
        records = list
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func add(deviceID: String, code: String, note: String) {
        let record = LicenseRecord(id: UUID(),
                                   deviceID: deviceID.uppercased(),
                                   code: code,
                                   note: note,
                                   createdAt: Date())
        records.insert(record, at: 0)
        persist()
        Log.info("授权", "签发记录新增 \(record.deviceID)")
    }

    func remove(_ record: LicenseRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    func code(forDeviceID deviceID: String) -> String? {
        let key = deviceID.uppercased()
        return records.first { $0.deviceID == key }?.code
    }

    func csv() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "设备码,授权码,备注,签发时间\n"
        for r in records {
            let note = r.note.replacingOccurrences(of: ",", with: " ")
            out += "\(r.deviceID),\(r.code),\(note),\(f.string(from: r.createdAt))\n"
        }
        return out
    }
}

// MARK: - 管理员验证（隐藏入口的第二道锁）

enum LicenseAdmin {
    private static let unlockedKey = "aurora.license.adminUnlocked"

    static var isUnlocked: Bool { UserDefaults.standard.bool(forKey: unlockedKey) }

    static func unlock() { UserDefaults.standard.set(true, forKey: unlockedKey) }

    /// 🔴 v2.9.11 安全修复（真实事故，2026-11-01）：
    ///   旧版本把管理口令**硬编码进二进制**（`static let passcode = "…"`），
    ///   而那个口令恰好就是管理员云账号的密码 → 任何人解压 IPA 就能拿到它、
    ///   登录管理员账号，把管理员设置的云端横幅换成自己的图（真实发生过一次）。
    ///   现在改成「用云账号的邮箱 + 密码登录校验」：
    ///   **App 内不再保存任何密码**，密码只从键盘输入、只发给 Supabase 校验，
    ///   拿到的令牌立刻丢弃（不建立会话、不落盘）。
    ///
    /// - Parameter requireAdmin: true = 只认管理员邮箱；false = 任何账号都能验密码
    ///   （实验室分两步走：先验密码 → 再判是不是管理员，不是一次性放行）。
    @discardableResult
    static func verify(email: String, password: String, requireAdmin: Bool = true) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !password.isEmpty else { return false }
        if requireAdmin && !SupabaseConfig.isAdminEmail(e) { return false }
        guard let url = URL(string: "\(SupabaseConfig.url)/auth/v1/token?grant_type=password") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["email": e, "password": password]) else { return false }
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

// MARK: - 生成器界面

struct LicenseGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LicenseRecordStore.shared

    /// 🔴 2026-11-07：用户要求「设置里连点 7 次版本」直接进生成器，**不用再验证云账号**。
    /// 生成器本身只在本地算授权码、记录存本机 UserDefaults，**不碰云端**，
    /// 所以从这个隐藏入口进来时不需要管理员账号校验。
    /// ⚠️ 实验室（LabView）里的入口仍保留校验——那里能改云端横幅，必须验管理员。
    let requireCloudLogin: Bool

    @State private var unlocked = false
    @State private var adminEmail = ""
    @State private var adminPassword = ""
    @State private var passError: String?
    @State private var verifying = false

    @State private var deviceInput = ""
    @State private var noteInput = ""
    @State private var search = ""
    @State private var toast: String?
    @State private var showShare = false
    @State private var shareText = ""

    init(requireCloudLogin: Bool = true) {
        self.requireCloudLogin = requireCloudLogin
        // 免验证入口直接放行；需要校验的入口沿用原来的判断（已解锁过 / 当前就是管理员）。
        _unlocked = State(initialValue: requireCloudLogin
                          ? (LicenseAdmin.isUnlocked || CloudAccount.shared.isAdmin)
                          : true)
    }

    private var trimmedDevice: String {
        deviceInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var computedCode: String {
        trimmedDevice.isEmpty ? "" : LicenseManager.expectedCode(for: trimmedDevice)
    }

    private var filtered: [LicenseRecord] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return store.records }
        return store.records.filter {
            $0.deviceID.contains(q) || $0.code.contains(q) || $0.note.uppercased().contains(q)
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if unlocked {
                    content
                } else {
                    passcodeGate
                }
            }
            .navigationTitle("授权码生成器")
            .navigationBarTitleDisplayMode(.inline)
            // 🔴 v2.9.6(修正)：二级页/弹窗的导航栏统一改成白色（主页那四个保持淡蓝渐变）
            .kugouNavigationBarBackground()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: 管理员账号校验

    private var passcodeGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(AppStyle.accent)
            Text("请登录管理员账号")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppStyle.primaryText)
            Text("用管理员的云账号邮箱和密码进入（密码不会被保存在本机）")
                .font(.system(size: 12))
                .foregroundStyle(AppStyle.tertiaryText)
                .multilineTextAlignment(.center)
            TextField("管理员邮箱", text: $adminEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .padding(12)
                .background(AppStyle.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            SecureField("密码", text: $adminPassword)
                .textContentType(.password)
                .padding(12)
                .background(AppStyle.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let err = passError {
                Text(err).font(.system(size: 12)).foregroundStyle(.red)
            }
            Button {
                passError = nil
                verifying = true
                Task {
                    let ok = await LicenseAdmin.verify(email: adminEmail, password: adminPassword)
                    await MainActor.run {
                        verifying = false
                        if ok {
                            adminPassword = ""
                            LicenseAdmin.unlock()
                            unlocked = true
                        } else {
                            passError = "邮箱或密码不正确"
                            Haptics.light()
                        }
                    }
                }
            } label: {
                if verifying {
                    ProgressView().controlSize(.small)
                } else {
                    Text("进入")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .disabled(verifying)
            Spacer()
        }
        .padding(20)
        .background(AppStyle.background)
    }

    // MARK: 主体

    private var content: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("设备码")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.secondaryText)
                    TextField("粘贴对方发来的设备码", text: $deviceInput)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if !trimmedDevice.isEmpty {
                        HStack(spacing: 8) {
                            Text(LicenseManager.pretty(computedCode))
                                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppStyle.primaryText)
                            Spacer(minLength: 4)
                            Button {
                                UIPasteboard.general.string = computedCode
                                toast("授权码已复制")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppStyle.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        if let existed = store.code(forDeviceID: trimmedDevice) {
                            Text("这台设备已签发过：\(LicenseManager.pretty(existed))")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 4)

                TextField("备注（选填，比如对方昵称）", text: $noteInput)
                    .font(.system(size: 14))

                Button {
                    guard !computedCode.isEmpty else { return }
                    store.add(deviceID: trimmedDevice, code: computedCode, note: noteInput)
                    toast("已保存到签发记录")
                    deviceInput = ""
                    noteInput = ""
                } label: {
                    Text("生成并保存记录")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppStyle.accent)
                }
                .disabled(computedCode.isEmpty)
            } header: {
                Text("签发")
            }

            Section {
                TextField("搜索设备码 / 授权码 / 备注", text: $search)
                    .font(.system(size: 14))

                if filtered.isEmpty {
                    Text(store.records.isEmpty ? "还没有签发记录" : "没有匹配的记录")
                        .font(.system(size: 12))
                        .foregroundStyle(AppStyle.tertiaryText)
                } else {
                    ForEach(filtered) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LicenseManager.pretty(record.code))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppStyle.primaryText)
                            Text(record.deviceID)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppStyle.tertiaryText)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if !record.note.isEmpty {
                                    Text(record.note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppStyle.secondaryText)
                                }
                                Spacer(minLength: 2)
                                Text(Self.dateString(record.createdAt))
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppStyle.tertiaryText)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = record.code
                                toast("授权码已复制")
                            } label: {
                                Label("复制授权码", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIPasteboard.general.string = record.deviceID
                                toast("设备码已复制")
                            } label: {
                                Label("复制设备码", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                store.remove(record)
                            } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    shareText = store.csv()
                    showShare = true
                } label: {
                    Label("导出全部记录（CSV）", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundStyle(AppStyle.accent)
                }
                .disabled(store.records.isEmpty)
            } header: {
                Text("签发记录（\(store.records.count)）")
            } footer: {
                if let t = toast {
                    Text(t).font(.system(size: 12)).foregroundStyle(AppStyle.accent)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    private func toast(_ text: String) {
        Haptics.light()
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == text { toast = nil }
        }
    }
}
