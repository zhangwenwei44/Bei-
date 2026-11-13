import SwiftUI
import AVFoundation
import UIKit

// MARK: - 🔴 2026-11-13：当前音频输出设备（蓝牙耳机）监测
//
// 只读 AVAudioSession.currentRoute，不需要任何权限，也不会激活/改动音频会话，
// 所以不会干扰播放器。routeChange 通知 + 回前台各补一次，保证 AirPods 拔插即时更新。
// ⚠️ 所有 @Published 都只写主线程（通知走 .main queue），避免 SwiftUI 在后台线程重算 body。
final class AudioRouteMonitor: ObservableObject {
    static let shared = AudioRouteMonitor()

    /// 当前输出是否为蓝牙设备（耳机 / 音箱 / 车载蓝牙）
    @Published private(set) var isBluetoothConnected = false
    /// 展示用的设备名（用户改过就用自定义名，否则用系统给的名字）
    @Published private(set) var deviceName = ""
    /// 系统原始设备名（改名的弹窗里用来「恢复默认」）
    @Published private(set) var originalName = ""
    /// 设备唯一标识（用来把自定义名绑定到具体设备，换耳机不会串名）
    @Published private(set) var deviceID = ""

    private let defaults = UserDefaults.standard
    private var tokens: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        // 部分机型从后台回来、或蓝牙在锁屏时连上，不会补发 routeChange。
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 重新读取当前输出设备。
    func refresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first { Self.isBluetooth($0.portType) }
        guard let port = port else {
            isBluetoothConnected = false
            deviceName = ""
            originalName = ""
            deviceID = ""
            return
        }
        let uid = port.uid.isEmpty ? port.portName : port.uid
        let systemName = port.portName.isEmpty ? "蓝牙设备" : port.portName
        let custom = defaults.string(forKey: Self.key(for: uid))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isBluetoothConnected = true
        deviceID = uid
        originalName = systemName
        deviceName = (custom?.isEmpty == false) ? (custom ?? systemName) : systemName
    }

    /// 给当前蓝牙设备改名（只保存在本机，不会改系统蓝牙设置里的名字）。
    func setDisplayName(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else { return }
        let name = String(trimmed.prefix(24))
        if name.isEmpty {
            defaults.removeObject(forKey: Self.key(for: deviceID))
        } else {
            defaults.set(name, forKey: Self.key(for: deviceID))
        }
        refresh()
    }

    /// 恢复系统自带的设备名。
    func resetDisplayName() {
        guard !deviceID.isEmpty else { return }
        defaults.removeObject(forKey: Self.key(for: deviceID))
        refresh()
    }

    private static func key(for uid: String) -> String {
        "aurora.audioDeviceName." + uid
    }

    /// 用 rawValue 判断，避开不同 iOS 版本里 bluetoothLE / bluetoothHFP 等符号的可用性差异。
    private static func isBluetooth(_ type: AVAudioSession.Port) -> Bool {
        type.rawValue.lowercased().contains("bluetooth")
    }
}

// MARK: - 🔴 2026-11-14 第八轮：蓝牙图标「只要蓝牙符号，移除浅灰方块底板」
//
// 系统 SF Symbols 里没有通用 Bluetooth 标志，`systemName:` 拼名字会静默渲染成空白，
// 所以符号全部手绘（标准 rune + 中部左右各一条短横，与用户给的参考图一致）。
struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var path = Path()
        // 主 rune：中竖线 + 上下两个右三角 + 交叉斜线
        path.move(to: p(6.5, 6.5))
        path.addLine(to: p(17.5, 17.5))
        path.addLine(to: p(12, 22))
        path.addLine(to: p(12, 2))
        path.addLine(to: p(17.5, 6.5))
        path.addLine(to: p(6.5, 17.5))
        // 参考图里符号中部左右各有一条短横
        path.move(to: p(2.5, 12))
        path.addLine(to: p(5.2, 12))
        path.move(to: p(18.8, 12))
        path.addLine(to: p(21.5, 12))
        return path
    }
}

/// 🔴 2026-11-14 第八轮：卡片右下角蓝牙设备图标 —— 只要蓝牙符号本身，
///    浅灰圆角方块底板已按用户要求移除。颜色跟随卡片：自定义背景图上用白字，
///    普通背景用主题蓝（都由调用方传 iconColor），保证任意背景都看得清。
struct BluetoothBadgeIcon: View {
    var size: CGFloat = 15
    var color: Color = Color(red: 0.239, green: 0.239, blue: 0.267)

    var body: some View {
        BluetoothMark()
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.072,
                                             lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - 呼吸发光圆点（主页顶栏状态标识前面用）
//
// 🔴 2026-11-13 第七轮：用户要求「发光圈再改小点」——圆点 5→4pt，
//    光晕 3 倍→2.2 倍、blur 3→1.8；并支持传颜色（音源绿=绿、红=红）。
struct BreathingStatusDot: View {
    var size: CGFloat = 4
    var color: Color = Color(red: 0.16, green: 0.76, blue: 0.38)
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(color.opacity(breathing ? 0.45 : 0.08))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .blur(radius: 1.8)
            }
            .scaleEffect(breathing ? 1.10 : 1.0)
            .animation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true),
                       value: breathing)
            .onAppear { breathing = true }
    }
}
