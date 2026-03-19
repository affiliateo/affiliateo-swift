import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Returns a stable device ID that persists across app launches.
/// Uses IDFV (Identifier for Vendor) on iOS — provided by Apple, no permissions needed.
/// Falls back to a UUID saved in UserDefaults if IDFV is unavailable.
func getStableDeviceId() -> String {
    // Try IDFV first (iOS only)
    #if canImport(UIKit) && !os(watchOS)
    if let idfv = UIDevice.current.identifierForVendor?.uuidString {
        return "ios-\(idfv)"
    }
    #endif

    // Fallback: generate a UUID once and save it
    let key = "com.affiliateo.device_id"
    if let saved = UserDefaults.standard.string(forKey: key) {
        return saved
    }

    let newId = "ios-\(UUID().uuidString)"
    UserDefaults.standard.set(newId, forKey: key)
    return newId
}
