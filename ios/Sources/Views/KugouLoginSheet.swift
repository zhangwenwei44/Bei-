import SwiftUI
import CoreImage.CIFilterBuiltins

/// 酷狗扫码登录 Sheet：展示二维码 + 轮询登录状态 + 保存登录态
struct KugouLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage?    // 🔴 缓存二维码图，避免每次渲染都重新 CIFilter
    @State private var statusText: String = "正在加载二维码…"
    @State private var isError: Bool = false
    @State private var errorMsg: String = ""
    @State private var isScanned: Bool = false
    @State private var isSuccess: Bool = false
    @State private var successName: String = ""
    @State private var isStarting = false  // 🔴 防并发：.onAppear 和手动刷新只允许一个 startLogin 跑
    @State private var pollTimer: Timer?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        CompatNavigationStack {
            ZStack {
                LinearGradient(colors: [.black, .gray.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    Text("酷狗音乐扫码登录")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)

                    if isSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                        Text("登录成功")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Text(successName)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    } else if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)

                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.72))

                        if isError {
                            Button("点击刷新") { startLogin(force: true) }
                                .buttonStyle(.borderedProminent)
                        }

                        Text("用酷狗音乐 App 扫码登录")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        ProgressView().tint(.white)
                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
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
        .onAppear {
            // 🔴 只在首次呈现时调 startLogin，.task 在 iOS 16 Sheet 里不可靠
            if qrImage == nil && !isStarting && !isSuccess {
                startLogin(force: false)
            }
        }
        .onDisappear { stopPolling() }
    }

    private func startLogin(force: Bool) {
        guard !isStarting || force else { return }
        isStarting = true
        stopPolling()
        qrImage = nil
        isError = false
        errorMsg = ""
        statusText = "正在加载二维码…"

        Task {
            defer { Task { @MainActor in isStarting = false } }
            do {
                let login = try await KugouClient.shared.qrKey()
                // 🔴 优先用 API 返回的 base64 二维码图（省 CIFilter 开销），没有才 fallback 本地生成
                let image: UIImage
                if let serverImg = login.qrcodeImg {
                    image = serverImg
                } else {
                    image = await MainActor.run { generateQRImage(from: login.url) }
                }
                await MainActor.run {
                    qrImage = image
                    statusText = "等待扫码…"
                    startPolling(key: login.key)
                }
            } catch {
                await MainActor.run {
                    isError = true
                    errorMsg = error.localizedDescription
                    statusText = "加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 🔴 纯函数：一次性生成二维码，存到 @State 后不再重复调用
    private func generateQRImage(from string: String) -> UIImage {
        let context = CIContext(options: nil)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let cg = context.createCGImage(output, from: output.extent)!
        return UIImage(cgImage: cg)
    }

    private func startPolling(key: String) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            pollOnce(key: key)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce(key: String) {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let newState = try await KugouClient.shared.pollQR(key: key)
                await MainActor.run {
                    switch newState {
                    case .waiting:
                        statusText = "等待扫码…"
                    case .scanned:
                        isScanned = true
                        statusText = "已扫码，请在手机上确认"
                    case .expired:
                        stopPolling()
                        isError = true
                        statusText = "二维码已过期，请点击刷新"
                    case .success(let name):
                        stopPolling()
                        isSuccess = true
                        successName = name
                        statusText = "登录成功！"
                        NotificationCenter.default.post(name: .auroraKugouLoginSuccess, object: nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
                    case .error(let msg):
                        // 单次轮询错误不致命，跳过
                        Log.warn("酷狗登录", "pollQR error: \(msg)")
                    }
                }
            } catch {
                // 网络抖动就跳过这一轮
            }
        }
    }
}
