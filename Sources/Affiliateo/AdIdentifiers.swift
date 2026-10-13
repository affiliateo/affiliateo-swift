import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppTrackingTransparency) && os(iOS)
import AppTrackingTransparency
#endif
#if canImport(AdSupport) && os(iOS)
import AdSupport
#endif

/// The advertising identifiers this device may share, read WITHOUT ever
/// asking for anything.
///
/// The SDK never shows the "Allow tracking?" prompt. That is the app's call,
/// and most apps never make it. What the SDK does is read the answer the app
/// already got:
///
/// - `trackingAllowed`: true only after the person tapped Allow, false after
///   they declined (or tracking is restricted), nil while the app has not
///   asked yet.
/// - `adId`: the IDFA, and only while tracking is allowed. iOS hands every
///   other app all zeros, which is never sent.
/// - `metaAnonId`: the Meta SDK's own anonymous id, when the app ships the
///   Meta SDK. It is what lets Meta tie a payment Affiliateo reports to the
///   install Meta's SDK saw. Found dynamically, so there is no dependency and
///   nothing at all happens in apps without it.
/// - `appPackage`: the bundle id, which Meta and Snapchat name the app by.
/// - `idfv`: Apple's identifier for vendor, sent as such so the server never
///   has to guess which device id is a real IDFV. The server forwards it only
///   while the person has not declined tracking.
///
/// These go to Affiliateo with identify and with `Affiliateo.purchase`, and
/// from there only to the ad networks the app's owner chose to send sales to.
struct AdIdentifiers {
    let adId: String?
    let trackingAllowed: Bool?
    let metaAnonId: String?
    let appPackage: String?
    let idfv: String?

    static func current() -> AdIdentifiers {
        let allowed = trackingAuthorization()
        return AdIdentifiers(
            adId: allowed == true ? advertisingId() : nil,
            trackingAllowed: allowed,
            metaAnonId: metaAnonymousId(),
            appPackage: Bundle.main.bundleIdentifier,
            idfv: vendorId()
        )
    }

    /// The fields as the server reads them. `ad_tracking_allowed` is always
    /// present (null while undecided) because "declined" has to reach the
    /// server to clear an id it stored earlier.
    var payload: [String: Any] {
        var out: [String: Any] = ["ad_tracking_allowed": trackingAllowed.map { $0 as Any } ?? NSNull()]
        if let adId { out["ad_id"] = adId }
        if let metaAnonId { out["meta_anon_id"] = metaAnonId }
        if let appPackage { out["app_package"] = appPackage }
        if let idfv { out["idfv"] = idfv }
        return out
    }

    /// The IDFV, or nil where UIKit has none (macOS) or iOS has not handed one
    /// out yet (right after a restore, before the first unlock).
    private static func vendorId() -> String? {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    /// The tracking prompt's answer. Reading it never shows the prompt.
    private static func trackingAuthorization() -> Bool? {
        #if canImport(AppTrackingTransparency) && os(iOS)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return nil
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }

    /// The IDFA, or nil when iOS hands back zeros.
    private static func advertisingId() -> String? {
        #if canImport(AdSupport) && os(iOS)
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString.lowercased()
        return id == "00000000-0000-0000-0000-000000000000" ? nil : id
        #else
        return nil
        #endif
    }

    /// `AppEvents.shared.anonymousID` from the Meta SDK, looked up by name
    /// (its Objective-C name is FBSDKAppEvents) so apps without it are untouched.
    private static func metaAnonymousId() -> String? {
        guard let appEvents = NSClassFromString("FBSDKAppEvents") as? NSObject.Type else { return nil }
        let sharedSelector = NSSelectorFromString("shared")
        guard appEvents.responds(to: sharedSelector),
              let shared = appEvents.perform(sharedSelector)?.takeUnretainedValue() as? NSObject else { return nil }
        let anonSelector = NSSelectorFromString("anonymousID")
        guard shared.responds(to: anonSelector),
              let anon = shared.perform(anonSelector)?.takeUnretainedValue() as? String,
              !anon.isEmpty else { return nil }
        return anon
    }
}
