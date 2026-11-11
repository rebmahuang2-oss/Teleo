import Foundation
import Network

/// 顯示目前網路類型（Wi-Fi／行動網路），因為連線需要 Wi-Fi。
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var label = "網路"
    @Published private(set) var icon = "network"
    @Published private(set) var isWiFi = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let label: String
            let icon: String
            let wifi: Bool
            if path.status != .satisfied {
                label = "無網路"; icon = "wifi.slash"; wifi = false
            } else if path.usesInterfaceType(.wifi) {
                label = "Wi-Fi"; icon = "wifi"; wifi = true
            } else if path.usesInterfaceType(.cellular) {
                label = "行動網路"; icon = "antenna.radiowaves.left.and.right"; wifi = false
            } else {
                label = "網路"; icon = "network"; wifi = false
            }
            Task { @MainActor in
                self?.label = label
                self?.icon = icon
                self?.isWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "virtualloc.netmon"))
    }

    deinit { monitor.cancel() }
}
