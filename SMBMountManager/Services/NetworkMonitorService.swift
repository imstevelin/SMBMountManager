import Foundation
import Network
import Combine

/// Monitors network path changes using NWPathMonitor and triggers mount reconnection
@MainActor
class NetworkMonitorService: ObservableObject {
    @Published var isConnected = true
    @Published var interfaceType: NWInterface.InterfaceType?
    @Published var lastChangeDate: Date?
    @Published var currentSSID: String?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
    private var previousStatus: NWPath.Status?
    private var previousSSID: String?
    var onNetworkChanged: (() -> Void)?

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                let wasConnected = self.isConnected
                self.isConnected = (path.status == .satisfied)
                self.interfaceType = path.availableInterfaces.first?.type
                let newSSID = WiFiService.currentSSID()
                let ssidChanged = (self.previousSSID != newSSID) && (self.previousStatus != nil)
                self.currentSSID = newSSID

                // Detect meaningful change (not just initial setup)
                let statusChanged = (self.previousStatus != nil && path.status != self.previousStatus)
                
                if statusChanged || ssidChanged {
                    self.lastChangeDate = Date()
                    // Trigger reconnection or rapid unmount evaluations on ALL meaningful transitions
                    self.onNetworkChanged?()
                }
                
                self.previousStatus = path.status
                self.previousSSID = newSSID
            }
        }
        monitor.start(queue: queue)
    }

    func stopMonitoring() {
        monitor.cancel()
    }

    var interfaceDescription: String {
        guard let type = interfaceType else { return "未知" }
        switch type {
        case .wifi: return "Wi-Fi"
        case .cellular: return "行動網路"
        case .wiredEthernet: return "乙太網路"
        case .loopback: return "本地迴路"
        default: return "其他"
        }
    }

    deinit {
        monitor.cancel()
    }
}
