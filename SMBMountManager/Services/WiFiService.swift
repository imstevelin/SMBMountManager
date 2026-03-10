import Foundation
import CoreWLAN
import CoreLocation

/// Provides Wi-Fi SSID detection using CoreWLAN
/// On macOS 14+, requires Location Services permission to read the SSID.
class WiFiService: NSObject, CLLocationManagerDelegate {
    private static let shared = WiFiService()
    private var locationManager: CLLocationManager?
    
    private override init() {
        super.init()
    }
    
    /// Request Location Services permission explicitly
    static func requestPermission() {
        if shared.locationManager == nil {
            shared.locationManager = CLLocationManager()
            shared.locationManager?.delegate = shared
        }
        if shared.locationManager?.authorizationStatus == .notDetermined {
            shared.locationManager?.requestWhenInUseAuthorization()
        }
    }

    /// Exposes authorization status for UI
    static var authorizationStatusString: String {
        switch shared.locationManager?.authorizationStatus ?? CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "已授權"
        case .denied, .restricted: return "未授權 (無法獲取 Wi-Fi 網路名稱)"
        case .notDetermined: return "等待授權"
        @unknown default: return "未知"
        }
    }
    
    /// Returns the SSID of the currently connected Wi-Fi network, or nil if unavailable
    static func currentSSID() -> String? {
        if shared.locationManager == nil || shared.locationManager?.authorizationStatus == .notDetermined {
            return nil
        }
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return interface.ssid()
    }

    /// Check if the current Wi-Fi matches one of the allowed SSIDs.
    /// If allowedSSIDs is empty, any network is allowed (no restriction).
    static func isOnAllowedNetwork(allowedSSIDs: [String]) -> Bool {
        // Empty list = no restriction
        if allowedSSIDs.isEmpty { return true }

        guard let ssid = currentSSID() else {
            // User specified allowed SSIDs, but we can't determine current SSID
            // (either user isn't on Wi-Fi or they denied location permission)
            // It MUST fail. We return false.
            return false
        }

        return allowedSSIDs.contains(ssid)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Handle authorization changes if needed
    }
}
