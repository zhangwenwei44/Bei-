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

// MARK: - 管理员口令（隐藏入口的第二道锁）

enum LicenseAdmin {
    /// 🔴 生成器的口令（连点 7 次版本区进入后要输一次，通过之后本机不再问）
    static let passcode = "8866"
    private static let unlockedKey = "aurora.license.adminUnlocked"

    static var isUnlocked: Bool { UserDefaults.standard.bool(forKey: unlockedKey) }

    static func unlock(_ input: String) -> Bool {
        guard input == passcode else { return false }
        UserDefaults.standard.set(true, forKey: unlockedKey)
        return true
    }
}

// MARK: - 生成器界面

struct LicenseGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LicenseRecordStore.shared

    @State private var unlocked = LicenseAdmin.isUnlocked
    @State private var passInput = ""
    @State private var passError: String?

    @State private var deviceInput = ""
    @State private var noteInput = ""
    @State private var search = ""
    @State private var toast: String?
    @State private var showShare = false
    @State private var shareText = ""

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
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: 口令

    private var passcodeGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(AppStyle.accent)
            Text("请输入管理口令")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppStyle.primaryText)
            SecureField("口令", text: $passInput)
                .textContentType(.password)
                .padding(12)
                .background(AppStyle.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let err = passError {
                Text(err).font(.system(size: 12)).foregroundStyle(.red)
            }
            Button {
                if LicenseAdmin.unlock(passInput) {
                    unlocked = true
                } else {
                    passError = "口令不对"
                    Haptics.light()
                }
            } label: {
                Text("进入")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppStyle.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
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
