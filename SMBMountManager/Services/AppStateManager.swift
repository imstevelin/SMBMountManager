import Foundation
import Combine

/// Manages global app states including First Launch onboarding and Post-Update authorization flows.
@MainActor
class AppStateManager: ObservableObject {
    static let shared = AppStateManager()
    
    @Published var needsOnboarding: Bool = false { didSet { updateReadyState() } }
    @Published var needsUpdateAuthorization: Bool = false { didSet { updateReadyState() } }
    @Published var needsErrorAuthorization: Bool = false
    
    @Published private(set) var isReadyToStartBackgroundEngines: Bool = false
    
    /// When upgrading from a pre-onboarding version, we need to show update auth FIRST,
    /// then show onboarding after the user completes update auth.
    private var needsOnboardingAfterUpdate: Bool = false
    
    private let lastLaunchedVersionKey = "org.imstevelin.SMBMountManager.lastLaunchedVersion"
    
    /// 1.5.0 is the first version that ships the interactive onboarding tutorial.
    private let firstOnboardingVersion = "1.5.0"
    
    private func updateReadyState() {
        isReadyToStartBackgroundEngines = !needsOnboarding && !needsUpdateAuthorization
    }
    
    private init() {
        checkAppVersion()
    }
    
    /// Compares the current app version against the last launched version stored in UserDefaults.
    private func checkAppVersion() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let lastVersion = UserDefaults.standard.string(forKey: lastLaunchedVersionKey)
        
        if lastVersion == nil {
            // First time ever launching the app → show onboarding
            needsOnboarding = true
        } else if let last = lastVersion, last.compare(currentVersion, options: .numeric) == .orderedAscending {
            // App was updated since last launch → always show update auth for Keychain re-authorization
            needsUpdateAuthorization = true
            
            // Check if upgrading from a version that had NO onboarding (< 1.5.0)
            // to one that HAS onboarding (>= 1.5.0). In that case, show onboarding
            // AFTER update auth completes.
            let lastHadOnboarding = last.compare(firstOnboardingVersion, options: .numeric) != .orderedAscending
            if !lastHadOnboarding {
                // User is jumping from a pre-onboarding version → defer onboarding until after update auth
                needsOnboardingAfterUpdate = true
            }
            // If last >= 1.5.0, user already saw onboarding → no need to show it again
        }
        
        // Note: We do NOT update UserDefaults here. We only update it explicitly when the user completes
        // the required flows, so if they hard-close the app during onboarding, it asks again next time.
        
        updateReadyState()
    }
    
    /// Mark onboarding as completed and record the current version to UserDefaults.
    func completeOnboarding() {
        needsOnboarding = false
        saveCurrentVersion()
    }
    
    /// Mark the update authorization flow as completed.
    /// If onboarding was deferred, activate it now.
    func completeUpdateAuthorization() {
        needsUpdateAuthorization = false
        
        if needsOnboardingAfterUpdate {
            needsOnboardingAfterUpdate = false
            needsOnboarding = true
        } else {
            saveCurrentVersion()
        }
    }
    
    func completeErrorAuthorization() {
        needsErrorAuthorization = false
    }
    
    /// Helper to stamp the current version into UserDefaults, signaling all update/onboarding tasks are done.
    private func saveCurrentVersion() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        UserDefaults.standard.set(currentVersion, forKey: lastLaunchedVersionKey)
    }
}
