import SwiftUI
import CoreImage.CIFilterBuiltins

/// 酷狗扫码登录 Sheet：展示二维码 + 轮询登录状态 + 保存登录态
struct KugouLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var kugouAuth = KugouAuth.shared

    @State private var qr: KugouClient.QRLogin?
    @State private var state: KugouClient.QRState = .waiting
    @State private var timer: Timer?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [.black, .gray.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    Text("酷狗音乐扫码登录")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)

                    if let qr {
                        qrView(for: qr.url)
                            .frame(width: 220, height: 220)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)

                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.72))

                        if case .expired = state {
                            Button("点击刷新") { startLogin() }
                                .buttonStyle(.borderedProminent)
                        }

                        Text("用酷狗音乐 App 扫码登录")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    } else if case .success(let name) = state {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                        Text("登录成功")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Text(name)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        ProgressView().tint(.white)
                    }

                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { stopPolling(); dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .task {
            if qr == nil { startLogin() }
        }
        .onDisappear { stopPolling() }
    }

    private var statusText: String {
        switch state {
        case .waiting: return "等待扫码…"
        case .scanned: return "已扫码，请在手机上确认"
        case .expired: return "二维码已过期"
        case .success(let name): return "登录成功！\(name)"
        case .error(let msg): return "出错了：\(msg)"
        }
    }

    private func startLogin() {
        stopPolling()
        state = .waiting
        Task {
            do {
                let login = try await KugouClient.shared.qrKey()
                await MainActor.run {
                    qr = login
                    startPolling()
                }
            } catch {
                await MainActor.run { state = .error(error.localizedDescription) }
            }
        }
    }

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            pollOnce()
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() {
        pollTask = Task {
            guard let key = qr?.key else { return }
            do {
                let newState = try await KugouClient.shared.pollQR(key: key)
                await MainActor.run {
                    state = newState
                    if case .success = newState {
                        stopPolling()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { dismiss() }
                    }
                    if case .expired = newState { stopPolling() }
                }
            } catch {
                // 网络抖动就跳过这一轮，保持 waiting
            }
        }
    }

    // MARK: - 二维码渲染（CoreImage CIFilter 生成，无需第三方库）

    private func qrView(for string: String) -> some View {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let cg = context.createCGImage(output, from: output.extent)!
        let ui = UIImage(cgImage: cg)
        return Image(uiImage: ui)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
    }
}
