import SwiftUI
import UIKit
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
        // 🔴 2026-11-08(二)：顶栏改成「完全透明 / 与下方同一层背景」。
        // 之前用深色实底 appearance 刷导航栏，和下面的深灰渐变对不上、有一条明显硬边
        //（用户反馈「顶栏颜色不好看与下面颜色不一致」）。
        // 现在不再套导航栈：整张 sheet 只有一层从顶铺到底的渐变，
        // 「取消」自绘在左上角浮在渐变上 —— 顶栏与下方是同一片背景，零色差。
        // 顺带避开项目里踩过的「透明导航栏露出 UIKit 容器白底」坑。
        ZStack {
            LinearGradient(colors: [.black, .gray.opacity(0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 自绘顶栏：只有「取消」，没有独立背景色
                HStack {
                    Button("取消") { stopPolling(); dismiss() }
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                VStack(spacing: 24) {
                    // 酷狗品牌登录图标 + 标题
                    VStack(spacing: 12) {
                        KugouLogoIcon(size: 64)
                        Text("酷狗音乐扫码登录")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }

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
        }
        // 兜底：sheet 卡片自身的系统背景压成深色，避免顶部圆角处露白；
        // 渐变末端的半透明灰也靠它显出深灰，整片背景连续。
        .background(Color(red: 0.09, green: 0.09, blue: 0.10).ignoresSafeArea())
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
