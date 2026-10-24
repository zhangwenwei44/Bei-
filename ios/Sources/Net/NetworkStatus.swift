import Foundation
import Combine
import Network

/// 网络类型检测（音质页「按网络环境选择音质」用）。
///
/// 🔴 v2.7.4：音质设置页底部有「设置不同网络环境下的播放音质」——
/// 蜂窝网络下自动降档省流量，这个开关要真的能判断当前是 WiFi 还是蜂窝。
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "aurora.network.status")

    /// 当前是否走蜂窝网络（4G/5G）
    @Published private(set) var isCellular = false
    /// 「个人热点/低数据模式」等昂贵网络
    @Published private(set) var isExpensive = false
    /// 是否有网络
    @Published private(set) var isConnected = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            let expensive = path.isExpensive
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCellular = cellular
                self.isExpensive = expensive
                self.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }
}
