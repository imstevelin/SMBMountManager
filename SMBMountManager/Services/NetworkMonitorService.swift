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
    private var previousInterfaceType: NWInterface.InterfaceType?
    var onNetworkChanged: (() -> Void)?

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                self.isConnected = (path.status == .satisfied)
                let activeInterface: NWInterface.InterfaceType?
                if path.usesInterfaceType(.wiredEthernet) {
                    activeInterface = .wiredEthernet
                } else if path.usesInterfaceType(.wifi) {
                    activeInterface = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    activeInterface = .cellular
                } else if path.usesInterfaceType(.loopback) {
                    activeInterface = .loopback
                } else if path.usesInterfaceType(.other) {
                    activeInterface = .other
                } else {
                    activeInterface = nil
                }
                self.interfaceType = activeInterface
                let newSSID = WiFiService.currentSSID()
                let ssidChanged = (self.previousSSID != newSSID) && (self.previousStatus != nil)
                let interfaceChanged = (self.previousInterfaceType != nil && self.previousInterfaceType != activeInterface)
                self.currentSSID = newSSID

                // Detect meaningful change (not just initial setup)
                let statusChanged = (self.previousStatus != nil && path.status != self.previousStatus)
                
                if statusChanged || ssidChanged || interfaceChanged {
                    self.lastChangeDate = Date()
                    // Trigger reconnection or rapid unmount evaluations on ALL meaningful transitions
                    self.onNetworkChanged?()
                }
                
                self.previousStatus = path.status
                self.previousSSID = newSSID
                self.previousInterfaceType = activeInterface
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
