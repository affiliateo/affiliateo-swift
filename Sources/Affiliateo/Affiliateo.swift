import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AdServices) && os(iOS)
import AdServices
#endif
#if canImport(StoreKit)
import StoreKit
#endif

/// Main entry point for the Affiliateo SDK.
/// Wrap your app with `AffiliateoProvider` to start tracking.
///
/// ```swift
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             AffiliateoProvider(appId: "YOUR_APP_ID") {
///                 ContentView()
///             }
///         }
///     }
/// }
/// ```
public struct AffiliateoProvider<Content: View>: View {
    let appId: String
    let apiUrl: String
    let content: () -> Content

    @StateObject private var manager: AffiliateoManager

    public init(
        appId: String,
        apiUrl: String = "https://affiliateo.com",
        debug: Bool = false,
        flushIntervalSecs: TimeInterval = 5,
        maxQueueSize: Int = 100,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.appId = appId
        self.apiUrl = apiUrl
        self.content = content
        _manager = StateObject(wrappedValue: AffiliateoManager(
            appId: appId,
            apiUrl: apiUrl,
            debug: debug,
            flushIntervalSecs: flushIntervalSecs,
            maxQueueSize: maxQueueSize
        ))
    }

    /// Pre-4.5.0 spelling. Affiliateo campaigns are now called apps.
    @available(*, deprecated, message: "Affiliateo campaigns are now apps — use init(appId:)")
    public init(
        campaignId: String,
        apiUrl: String = "https://affiliateo.com",
        debug: Bool = false,
        flushIntervalSecs: TimeInterval = 5,
        maxQueueSize: Int = 100,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            appId: campaignId,
            apiUrl: apiUrl,
            debug: debug,
            flushIntervalSecs: flushIntervalSecs,
            maxQueueSize: maxQueueSize,
            content: content
        )
    }

    public var body: some View {
        content()
            .environmentObject(manager)
            .onAppear { manager.start() }
    }
}

/// Access the affiliate ref code and attribution state from any view.
///
/// ```swift
/// struct ContentView: View {
///     @EnvironmentObject var affiliateo: AffiliateoManager
///
///     var body: some View {
///         if affiliateo.state.isMatched {
///             Text("Referred by: \(affiliateo.state.refCode ?? "")")
///         }
///     }
/// }
/// ```
public final class AffiliateoManager: ObservableObject {
    @Published public private(set) var state = AffiliateoState(
        refCode: nil,
        isMatched: false,
        isLoading: true,
        visitorId: nil
    )

    /// The most recently created manager. Used by the static `Affiliateo.page()`
    /// and `Affiliateo.track()` helpers so merchants can fire events without
    /// threading an `@EnvironmentObject` through every view.
    public internal(set) static weak var shared: AffiliateoManager?

    // Persistent opt-out flag. Mirrors @affiliateo/react-native 4.0.0 +
    // @affiliateo/web 3.0.0 behavior. When set to "true" the SDK silently
    // noops every outbound call until optIn() flips it. Stored in
    // UserDefaults so the flag survives app restarts; the
    // `@objc dynamic var` form isn't needed here because we only ever
    // read/write through the SDK's own methods.
    private static let optOutKey = "affiliateo_opt_out"
    // Who is signed in (4.11.0), kept so the SDK can re-send it once per
    // launch, and a sign-out the server has not heard yet. Same plain-key
    // style as the opt-out flag, and the same names as the React Native SDK.
    private static let userIdKey = "affiliateo_user_id"
    private static let logoutPendingKey = "affiliateo_logout_pending"
    // The signed-in user's email as a SHA-256 (4.12.0), never the address,
    // kept with the user id so the once-per-launch re-send carries it too.
    private static let emailHashKey = "affiliateo_email_sha256"

    private let campaignId: String
    private let apiUrl: String
    private let client: AffiliateoClient
    // Never changes for the life of the install: logout() and reset() keep it.
    private let deviceId: String
    private let queue: EventQueue
    private var started = false
    // In-memory mirror of the on-disk opt-out flag. Hot-path check
    // inside every track/page/identify call; refreshed on optOut/optIn
    // calls so a mid-session decision applies immediately.
    private var isOptedOut: Bool
    // Debug flag. When true, every SDK decision (init, page, track,
    // identify, flush, opt in/out, reset) is printed to the Xcode console
    // via print(). Only useful during development. ship with debug=false
    // (the default) so production apps don't pay the print overhead AND
    // don't leak SDK internals to anyone running their app under a
    // debugger. Mirrors @affiliateo/web and @affiliateo/react-native.
    private let debug: Bool

    // Sign-in state (4.11.0). Read and written on the main actor only, so
    // identify / logout / the launch re-send never race each other.
    /// The signed-in user id, mirrored in UserDefaults.
    private var userId: String?
    /// The user the server confirmed (linked) this launch: identify with the
    /// same id sends nothing.
    private var syncedUser: String?
    /// The user id whose identify-user call is on its way.
    private var userInFlight: String?
    /// This launch's first /api/v1/mobile/identify succeeded, so the server
    /// knows the device and a sign-in can link to it.
    private var firstOpenDone = false
    /// A logout call on its way; a sign-in waits for it.
    private var logoutTask: Task<Void, Never>?
    /// SHA-256 of the signed-in user's email (4.12.0), mirrored in
    /// UserDefaults; nil when the app gave none.
    private var emailHash: String?
    /// The email hash the server confirmed along with `syncedUser`.
    private var syncedEmailHash: String?
    /// Goes up on sign-out and when a different user signs in, so a free
    /// access answer for the person before is neither saved nor returned.
    private var freeAccessEpoch = 0

    // This launch's first identify, and the latest identify or logout call
    // (4.12.0): freeAccess() asks once the server has heard them. Set from
    // whichever thread the app calls on, hence the lock.
    private let workLock = NSLock()
    private var launchWork: Task<Void, Never>?
    private var signInWork: Task<Void, Never>?

    public init(
        appId: String,
        apiUrl: String = "https://affiliateo.com",
        debug: Bool = false,
        flushIntervalSecs: TimeInterval = 5,
        maxQueueSize: Int = 100
    ) {
        self.campaignId = appId
        self.apiUrl = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
        self.client = AffiliateoClient(apiUrl: apiUrl)
        self.deviceId = getStableDeviceId()
        // Queue tuning. Both clamped inside EventQueue.init so a host
        // passing 0 or 999999 won't break us.
        self.queue = EventQueue(
            flushIntervalSecs: flushIntervalSecs,
            maxQueueSize: maxQueueSize
        )
        self.isOptedOut = UserDefaults.standard.string(forKey: AffiliateoManager.optOutKey) == "true"
        self.debug = debug
        self.userId = AffiliateoUserId.usable(UserDefaults.standard.string(forKey: AffiliateoManager.userIdKey))
        self.emailHash = userId == nil ? nil : UserDefaults.standard.string(forKey: AffiliateoManager.emailHashKey)
        AffiliateoManager.shared = self
    }

    /// Pre-4.5.0 spelling. Affiliateo campaigns are now called apps.
    @available(*, deprecated, message: "Affiliateo campaigns are now apps — use init(appId:)")
    public convenience init(
        campaignId: String,
        apiUrl: String = "https://affiliateo.com",
        debug: Bool = false,
        flushIntervalSecs: TimeInterval = 5,
        maxQueueSize: Int = 100
    ) {
        self.init(
            appId: campaignId,
            apiUrl: apiUrl,
            debug: debug,
            flushIntervalSecs: flushIntervalSecs,
            maxQueueSize: maxQueueSize
        )
    }

    /// Internal debug logger. No-op unless `debug: true` was passed to init.
    /// Single-arg form for messages without payload; two-arg form for
    /// messages with structured data. Output goes to the standard Xcode
    /// console (visible in DevTools / debug navigator while attached).
    private func log(_ msg: String, _ data: Any? = nil) {
        guard debug else { return }
        if let data = data {
            print("[Affiliateo] \(msg)", data)
        } else {
            print("[Affiliateo] \(msg)")
        }
    }

    /// Start tracking. Called automatically by AffiliateoProvider.
    /// Runs identify (mints visitor + matches affiliate) and registers the
    /// foreground keep-alive ping. Screens are NOT auto-tracked. the host
    /// app calls Affiliateo.page(name) per screen, matching the Mixpanel /
    /// Amplitude mobile model.
    func start() {
        guard !started else { return }
        started = true

        // Live Chat calls the app made before the provider was up (4.14.0).
        // The chat works while opted out too; it only leaves the ids out.
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.managerStarted() }
        #endif

        // Opted-out fast path. Skip identify + foreground ping entirely.
        // The state is published with isLoading=false so any host UI
        // gated on it (e.g. a paywall waiting for the matched? check)
        // unblocks immediately. Public methods still exist and noop
        // until optIn() flips the flag back.
        if isOptedOut {
            log("blocked: opted out (call optIn() to re-enable)")
            self.state = AffiliateoState(
                refCode: nil,
                isMatched: false,
                isLoading: false,
                visitorId: nil,
                appAccountToken: nil
            )
            return
        }

        log("init", ["app": campaignId, "device": deviceId])
        let launch = Task {
            await identify()
        }
        workLock.lock()
        launchWork = launch
        workLock.unlock()

        // Keep the server-side session alive on foreground. The server's
        // start_mobile_session RPC handles rotation based on the 10-minute
        // inactivity timeout. No background screen_view. that was a ghost
        // event that polluted funnels.
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        #endif
    }

    /// Fire a screen_view event for a specific screen.
    /// Call from `onAppear` in SwiftUI or `viewDidAppear` in UIKit.
    public func page(_ screenName: String, metadata: [String: Any]? = nil) {
        // Live Chat's screen rules follow the screen, opted out or not (4.14.0).
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.screenChanged(screenName) }
        #endif
        if isOptedOut { return }
        log("page", ["screen": screenName, "metadata": metadata as Any])
        // Build the wire payload here (instead of via client.sendEvents)
        // so we can enqueue it for retry. The endpoint + body shape match
        // what client.sendEvents would have sent.
        var event: [String: Any] = [
            "type": EventType.screenView.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "screen": screenName,
            // Dedup key, stamped HERE rather than at send time so the queued
            // payload carries one fixed id through every retry. The server
            // keeps a unique index on it and drops replays.
            "event_id": UUID().uuidString.lowercased(),
        ]
        if let metadata = metadata { event["metadata"] = metadata }
        queue.enqueue(
            endpoint: "\(apiUrl)/api/v1/mobile/event",
            payload: [
                "campaign_id": campaignId,
                "device_id": deviceId,
                "events": [event],
            ]
        )
    }

    /// Fire a custom event with arbitrary name + metadata.
    public func track(_ eventName: String, metadata: [String: Any]? = nil) {
        if isOptedOut { return }
        log("track", ["event": eventName, "metadata": metadata as Any])
        var merged: [String: Any] = ["event": eventName]
        if let metadata = metadata {
            for (k, v) in metadata { merged[k] = v }
        }
        let event: [String: Any] = [
            "type": EventType.custom.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "metadata": merged,
            // The event type where a duplicate actually costs something: a
            // replayed custom event is a double-counted funnel conversion.
            // Stamped at creation so every retry sends the same id.
            "event_id": UUID().uuidString.lowercased(),
        ]
        queue.enqueue(
            endpoint: "\(apiUrl)/api/v1/mobile/event",
            payload: [
                "campaign_id": campaignId,
                "device_id": deviceId,
                "events": [event],
            ]
        )
    }

    /// The user signed out (4.11.0). Call it on sign-out: this device starts
    /// over as a new anonymous customer of the app, so whoever signs in next
    /// (or nobody) is not counted as the person who just left, and
    /// everything already recorded stays with them. Forgets the stored user
    /// id, their email hash, the saved free access answer and (4.14.2) their
    /// Live Chat thread: the next person to open the chat starts a new one.
    ///
    /// Tracking carries on: same device id, same visitor id, same
    /// `appAccountToken`, nothing to relaunch. A sign-out made offline (or
    /// while opted out) is sent after the next launch's identify.
    public func logout() {
        log("logout requested")
        // Right away, not in the task: a freeAccess() that cannot reach the
        // server must not unlock from the person who just left.
        FreeAccessCache.clear()
        // Nor may the chat open their thread (4.14.2).
        UserDefaults.standard.removeObject(forKey: ChatRules.tokenKey(campaignId))
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.forget() }
        #endif
        let task = Task { @MainActor in
            self.userId = nil
            self.syncedUser = nil
            self.emailHash = nil
            self.syncedEmailHash = nil
            self.freeAccessEpoch += 1
            FreeAccessCache.clear()
            UserDefaults.standard.removeObject(forKey: AffiliateoManager.userIdKey)
            UserDefaults.standard.removeObject(forKey: AffiliateoManager.emailHashKey)
            UserDefaults.standard.set("true", forKey: AffiliateoManager.logoutPendingKey)
            await self.sendLogout()
        }
        setSignInWork(task)
    }

    /// The same as `logout()` since 4.11.0.
    ///
    /// It used to try to mint a new device id (impossible: the IDFV belongs to
    /// the app's vendor) and cleared the state, which left `appAccountToken`
    /// nil until the app relaunched. Kept so existing apps keep compiling and
    /// now get the sign-out they meant.
    public func reset() {
        logout()
    }

    /// Stop tracking on this device. Sets the persistent opt-out flag
    /// in UserDefaults and silences ALL subsequent page / track /
    /// identify calls until optIn() is called. Survives app restart.
    /// Pending queued events are dropped — the visitor explicitly said
    /// no, sending events captured before the decision would still
    /// violate consent. Use for GDPR/CCPA "Don't track me" consent.
    public func optOut() {
        log("optOut")
        isOptedOut = true
        UserDefaults.standard.set("true", forKey: AffiliateoManager.optOutKey)
        queue.clear()
    }

    /// Re-enable tracking after a previous optOut(). The auto session
    /// start that fires on provider mount won't retroactively replay —
    /// to resume immediately the host should reinitialize the manager
    /// (e.g. tear down and re-create AffiliateoProvider).
    public func optIn() {
        log("optIn")
        isOptedOut = false
        UserDefaults.standard.removeObject(forKey: AffiliateoManager.optOutKey)
    }

    /// Force-drain the event queue immediately. Useful before a known
    /// unrecoverable transition (entering an in-app purchase flow,
    /// app about to be backgrounded for a long time). Best-effort: if
    /// offline the flush noops and events stay queued for the next
    /// retry cycle.
    public func flush() async {
        log("flush requested")
        await queue.flush()
    }

    /// Say who is signed in. Call after sign-in, and on launch while someone
    /// is signed in. The same person then counts as ONE customer across
    /// devices, reinstalls, and the anonymous to signed-in handoff. A
    /// different user signing in on this device switches it to them (since
    /// 4.11.0; it used to be refused).
    ///
    /// The SDK stores the id and re-sends it once per launch. A sign-in that
    /// raced ahead of the launch's first identify is sent again right after
    /// it. Does nothing while opted out, and skips ids that mean "nobody"
    /// ("null", "undefined", "guest", "0", RevenueCat's $RCAnonymousID:...).
    ///
    /// `email` (4.12.0, optional) is the address the person signed in with.
    /// It never leaves the phone: the SDK sends only its SHA-256 (trimmed and
    /// lowercased first), which is how an affiliate the app owner gave free
    /// access is recognised (see `freeAccess()`). Leave it out and the hash
    /// already stored for this user is kept.
    public func identify(_ userId: String, email: String? = nil) {
        if isOptedOut {
            log("identify skipped: opted out")
            return
        }
        guard let uid = AffiliateoUserId.usable(userId) else {
            log("identify skipped: not a user id (empty, over 128 characters, or a placeholder like \"null\", \"guest\" or \"0\")", ["user_id": userId])
            return
        }
        let hash = AffiliateoEmail.sha256Hex(email)
        let task = Task { @MainActor in
            if self.userId != uid {
                self.userId = uid
                UserDefaults.standard.set(uid, forKey: AffiliateoManager.userIdKey)
                // Somebody else: their own email (or none), and no free access
                // answer that belonged to the person before.
                self.setEmailHash(hash)
                self.freeAccessEpoch += 1
                FreeAccessCache.clear()
            } else if let hash, hash != self.emailHash {
                self.setEmailHash(hash)
            }
            // A sign-in replaces a sign-out that never reached the server: a
            // different person signing in switches the device anyway.
            UserDefaults.standard.removeObject(forKey: AffiliateoManager.logoutPendingKey)
            // Already confirmed this launch: nothing to send.
            if self.syncedUser == uid && self.syncedEmailHash == self.emailHash { return }
            await self.sendIdentifyUser(uid)
        }
        setSignInWork(task)
    }

    /// The signed-in user's email hash, mirrored in UserDefaults.
    @MainActor
    private func setEmailHash(_ hash: String?) {
        emailHash = hash
        if let hash {
            UserDefaults.standard.set(hash, forKey: AffiliateoManager.emailHashKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AffiliateoManager.emailHashKey)
        }
    }

    // Not async, because NSLock must not be held across a suspension point.
    private func setSignInWork(_ task: Task<Void, Never>) {
        workLock.lock()
        signInWork = task
        workLock.unlock()
    }

    private func pendingSignInWork() -> [Task<Void, Never>] {
        workLock.lock()
        defer { workLock.unlock() }
        return [launchWork, signInWork].compactMap { $0 }
    }

    /// POST /api/v1/mobile/identify-user for the signed-in user. A 400 is not
    /// retried (and the stored id is forgotten); a network or server error
    /// leaves it stored for the next launch; `.notLinked` is sent once more
    /// when this launch's first identify finished while it was on its way,
    /// and a new email given while it was on its way is sent right after.
    @MainActor
    private func sendIdentifyUser(_ uid: String) async {
        // Already on its way: that call's answer decides what happens next.
        if userInFlight == uid { return }
        userInFlight = uid
        defer { if userInFlight == uid { userInFlight = nil } }
        for _ in 0..<3 {
            // A sign-out still on its way lands first, so it cannot undo this.
            if let pending = logoutTask { await pending.value }
            guard !isOptedOut, userId == uid else { return }
            let beforeFirstOpen = !firstOpenDone
            let sentHash = emailHash
            let result: IdentifyUserResult
            do {
                result = try await client.identifyUser(campaignId: campaignId, deviceId: deviceId, userId: uid, emailSha256: sentHash)
            } catch {
                log("identify failed (network), sent again next launch", ["user_id": uid])
                return
            }
            // Signed out, or somebody else signed in, while this was in flight.
            guard userId == uid else { return }
            switch result {
            case .linked(let outcome):
                syncedUser = uid
                syncedEmailHash = sentHash
                log("identify (user)", ["user_id": uid, "outcome": outcome as Any, "email_sha256": sentHash as Any])
                // A new email came in while this was on its way.
                if emailHash == sentHash { return }
            case .refused:
                log("identify refused by the server (400), not retried", ["user_id": uid])
                userId = nil
                setEmailHash(nil)
                UserDefaults.standard.removeObject(forKey: AffiliateoManager.userIdKey)
                return
            case .notLinked:
                guard beforeFirstOpen && firstOpenDone else {
                    log("identify: device not known yet, sent again after the first identify", ["user_id": uid])
                    return
                }
                log("identify: device known now, sending again", ["user_id": uid])
            }
        }
    }

    /// POST /api/v1/mobile/logout. The pending flag is cleared only once the
    /// server has it; until then the next launch sends it again.
    @MainActor
    private func sendLogout() async {
        if isOptedOut { return }
        let task = Task { @MainActor in
            do {
                let outcome = try await self.client.logout(campaignId: self.campaignId, deviceId: self.deviceId)
                self.log("logout", ["outcome": outcome as Any])
                // Nobody signed in meanwhile (a sign-in clears the flag itself).
                if self.userId == nil {
                    UserDefaults.standard.removeObject(forKey: AffiliateoManager.logoutPendingKey)
                }
            } catch {
                self.log("logout failed (network), sent again next launch")
            }
        }
        logoutTask = task
        await task.value
        if logoutTask == task { logoutTask = nil }
    }

    /// After this launch's first identify: the stored user if the server has
    /// not confirmed it yet (which also covers a sign-in that answered
    /// `.notLinked`), or a sign-out it never heard.
    @MainActor
    private func syncSignedInUser() async {
        firstOpenDone = true
        if let uid = userId {
            if syncedUser != uid || syncedEmailHash != emailHash { await sendIdentifyUser(uid) }
        } else if UserDefaults.standard.string(forKey: AffiliateoManager.logoutPendingKey) == "true" {
            await sendLogout()
        }
    }

    /// Whether the app owner gave the signed-in person free access from their
    /// Affiliateo dashboard (4.12.0). For apps that sell with StoreKit, Google
    /// Play Billing, Adapty or Stripe directly, where Affiliateo cannot hand
    /// out a subscription itself; apps on RevenueCat get a RevenueCat
    /// entitlement instead and need none of this.
    ///
    /// ```swift
    /// Affiliateo.identify(user.id, email: user.email)
    /// if await Affiliateo.freeAccess().active { unlock() }
    /// ```
    ///
    /// The person is recognised by the email given to `identify(_:email:)`,
    /// so call that first; the check waits (up to 10 seconds) for this
    /// launch's first identify and the latest sign-in or sign-out to reach
    /// the server. `productId` names the plan the owner chose (nil means full
    /// access) and `expiresAt` when it ends (nil means no end).
    ///
    /// Never throws. Each answer is saved on the phone; when the server
    /// cannot be reached (or the person has opted out, when nothing is sent)
    /// the saved answer is used while its end is still ahead and it is at
    /// most 7 days old, otherwise the answer is no access. Signing out, or a
    /// different user signing in, forgets the saved answer.
    @MainActor
    public func freeAccess() async -> AffiliateoFreeAccess {
        await waitForSignIn(seconds: 10)
        if isOptedOut {
            let saved = FreeAccessCache.offlineAnswer(FreeAccessCache.load(), now: Date())
            log("freeAccess: opted out, answered from the phone", ["active": saved.active])
            return saved
        }
        let epoch = freeAccessEpoch
        do {
            let answer = try await client.freeAccess(campaignId: campaignId, deviceId: deviceId)
            // Signed out, or somebody else signed in, while this was asked.
            guard epoch == freeAccessEpoch else { return .inactive }
            FreeAccessCache.save(FreeAccessCache.Entry(answer, checkedAt: Date()))
            log("freeAccess", [
                "active": answer.active,
                "product_id": answer.productId as Any,
                "expires_at": answer.expiresAt as Any,
            ])
            return answer
        } catch {
            guard epoch == freeAccessEpoch else { return .inactive }
            let saved = FreeAccessCache.offlineAnswer(FreeAccessCache.load(), now: Date())
            log("freeAccess failed, answered from the phone", ["active": saved.active])
            return saved
        }
    }

    /// Until this launch's first identify (with the sign-in sync after it)
    /// and the latest identify or logout have finished, or `seconds` passed.
    private func waitForSignIn(seconds: Double) async {
        let pending = pendingSignInWork()
        if pending.isEmpty { return }
        // Awaiting a task's value cannot be cancelled, so the time limit is a
        // race between the two, and the first to finish resumes.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume()
            }
            Task {
                for task in pending { await task.value }
                once.resume()
                timer.cancel()
            }
        }
    }

    /// Report the host app's RevenueCat App User ID
    /// (`Purchases.shared.appUserID`). Call once after RevenueCat has
    /// configured; safe to call on every launch.
    ///
    /// Lets an app owner grant this affiliate complimentary access to the app
    /// from their Affiliateo dashboard. Separate from `identify` on purpose:
    /// sign-in and RevenueCat configuration happen at different moments, and
    /// an app may do one without the other.
    ///
    /// No email or other PII is sent.
    public func setRevenueCatUser(_ appUserId: String) {
        let rcId = appUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        // 255 matches the server. RevenueCat's anonymous form
        // ($RCAnonymousID:<32 hex>) is already ~50 characters.
        guard !rcId.isEmpty, rcId.count <= 255 else { return }
        log("setRevenueCatUser", ["revenuecat_user_id": rcId])
        Task {
            try? await client.identifyRevenueCatUser(
                campaignId: campaignId,
                deviceId: deviceId,
                revenueCatUserId: rcId
            )
        }
    }

    private func identify() async {
        do {
            let deviceInfo = DeviceInfo.current()
            let adIdentifiers = AdIdentifiers.current()
            let result = try await client.identify(
                campaignId: campaignId,
                deviceId: deviceId,
                deviceInfo: deviceInfo,
                adIdentifiers: adIdentifiers
            )
            lastSentTracking = .some(adIdentifiers.trackingAllowed)

            // Apple native IAP attribution (4.10.0). The purchase tag is the
            // visitor id itself, for EVERY device, matched or organic: Apple
            // needs a UUID and the visitor id is one (v4). The app reads it
            // via state.appAccountToken and passes it as
            // .appAccountToken(uuid) to StoreKit 2's product.purchase(options:),
            // Apple stamps it onto the whole purchase chain (first buy, every
            // renewal, refund), and the server matches it to this visitor
            // directly, so nothing is registered from here. Tokens minted per
            // affiliate before 4.10.0 keep working server side, and a chain
            // bought with one keeps carrying it.
            let appleToken = UUID(uuidString: result.visitorId)

            await MainActor.run {
                self.state = AffiliateoState(
                    refCode: result.refCode,
                    isMatched: result.matched,
                    isLoading: false,
                    visitorId: result.visitorId,
                    appAccountToken: appleToken
                )
            }
            log("identify success", [
                "visitor": result.visitorId,
                "matched": result.matched,
                "ref": result.refCode as Any,
            ])

            // The server knows this device now: bring it up to date on who
            // is signed in. Awaited at the end, so this launch's work
            // (which freeAccess() waits for) includes it.
            let signInSync = Task { @MainActor in await self.syncSignedInUser() }

            // Apple Search Ads attribution: grab the AdServices token for
            // EVERY install (not just affiliate matches — most paid installs
            // have no affiliate) so the backend can say which ASA keyword
            // drove this install. No ATT prompt involved.
            registerAdServicesAttribution(visitorId: result.visitorId)

            // Auto-set RevenueCat subscriber attributes. The visitor id goes
            // on EVERY identify (matched or organic): the webhook stamps it
            // onto campaign_conversions.visitor_id, which powers the per-buyer
            // Spent column, funnels journeys, and the ad ROAS/LTV joins. The
            // ref code rides along only when the install matched an affiliate.
            setRevenueCatAttributes(visitorId: result.visitorId, refCode: result.refCode)

            // …and read back which RevenueCat customer this device is, so the
            // owner's Access switch has someone to grant to.
            reportRevenueCatAppUserId()

            // The App Store's own price for the app's products, from a US
            // phone, once a day, in the background (4.13.0). Never blocks.
            if !isOptedOut {
                AffiliateoStorePrices.reportIfDue(client: client, campaignId: campaignId, deviceId: deviceId)
            }

            await signInSync.value
        } catch {
            log("identify failed (network error)")
            await MainActor.run {
                self.state = AffiliateoState(
                    refCode: nil,
                    isMatched: false,
                    isLoading: false,
                    visitorId: nil,
                    appAccountToken: nil
                )
            }
        }
    }

    /// Grab Apple's AdServices attribution token (iOS 14.3+, package floor is
    /// 15 so the framework always exists) and hand it to the backend, which
    /// redeems it with Apple. Once per install: the sent flag persists in
    /// UserDefaults, a failed send retries next launch. The token call is
    /// documented as main-thread-unsafe work, so it runs detached at utility
    /// priority. Returns nil on Simulator — silently skipped.
    private func registerAdServicesAttribution(visitorId: String) {
        #if canImport(AdServices) && os(iOS)
        let flagKey = "affiliateo_asa_token_sent:\(campaignId)"
        guard UserDefaults.standard.string(forKey: flagKey) == nil else { return }
        let cid = campaignId
        let client = self.client
        Task.detached(priority: .utility) {
            guard let token = try? AAAttribution.attributionToken() else { return }
            do {
                try await client.registerAppleAdsToken(campaignId: cid, visitorId: visitorId, token: token)
                UserDefaults.standard.set("1", forKey: flagKey)
            } catch {
                // Next launch retries; the backend dedups by visitor.
            }
        }
        #endif
    }

    /// Set once we have successfully reached `Purchases.shared`. Gates the
    /// foreground re-read below — see the warning on `revenueCatShared()`.
    private var revenueCatReachable = false

    /// RevenueCat's `Purchases.shared`, or nil when RevenueCat isn't in the
    /// app at all (most apps). Dynamic lookup so we never take a hard
    /// dependency on it.
    ///
    /// NOT safe before the host app has called `Purchases.configure`: `shared`
    /// traps in that case, and RevenueCat exposes no probe for it that can be
    /// read through `perform` (`isConfigured` returns a BOOL, and `perform` is
    /// only defined for object returns). So the safety here is entirely about
    /// WHEN this is called. Every caller runs after identify's network
    /// round-trip, which the attributes call below has shipped on since 4.x
    /// without incident, and `revenueCatReachable` keeps the foreground path
    /// from reaching it any earlier than that on a cold launch.
    private func revenueCatShared() -> AnyObject? {
        guard let purchasesClass = NSClassFromString("RCPurchases") as? NSObject.Type else { return nil }
        let sharedSelector = NSSelectorFromString("sharedPurchases")
        guard purchasesClass.responds(to: sharedSelector),
              let shared = purchasesClass.perform(sharedSelector)?.takeUnretainedValue() else { return nil }
        revenueCatReachable = true
        return shared
    }

    private func setRevenueCatAttributes(visitorId: String, refCode: String?) {
        guard let shared = revenueCatShared() else { return }

        let setAttrSelector = NSSelectorFromString("setAttributes:")
        if shared.responds(to: setAttrSelector) {
            // affiliateo_visitor_id links RevenueCat webhook events back to
            // this device's tracked visitor. Without it every conversion
            // lands with visitor_id NULL and per-buyer analytics stay dark.
            var attributes: [String: String] = ["affiliateo_visitor_id": visitorId]
            if let refCode { attributes["affiliateo_ref"] = refCode }
            shared.perform(setAttrSelector, with: attributes)
        }
    }

    /// Report WHICH RevenueCat customer this device is — the only thing that
    /// lets an app owner grant this affiliate free access from their Affiliateo
    /// dashboard.
    ///
    /// Read rather than waiting to be told. This shipped as a
    /// `setRevenueCatUser()` call the merchant had to add themselves, and an
    /// install step that gets skipped leaves the feature silently dead with
    /// nothing to say why. RevenueCat is already running in the app.
    ///
    /// Safe to call repeatedly: an unchanged id is a no-op server-side. Called
    /// on identify AND on foreground, because the first id we see is usually
    /// RevenueCat's anonymous placeholder — it only becomes the real one when
    /// the app calls `logIn`, which almost always happens after we started. The
    /// server permits exactly one upgrade from that placeholder to a real id.
    private func reportRevenueCatAppUserId() {
        if isOptedOut { return }
        guard let shared = revenueCatShared() else { return }

        let appUserIdSelector = NSSelectorFromString("appUserID")
        guard shared.responds(to: appUserIdSelector),
              let raw = shared.perform(appUserIdSelector)?.takeUnretainedValue() as? String else { return }

        let rcId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 255 matches the server. RevenueCat's anonymous form
        // ($RCAnonymousID:<32 hex>) is already ~50 characters.
        guard !rcId.isEmpty, rcId.count <= 255 else { return }

        log("setRevenueCatUser (auto)", ["revenuecat_user_id": rcId])
        Task {
            try? await client.identifyRevenueCatUser(
                campaignId: campaignId,
                deviceId: deviceId,
                revenueCatUserId: rcId
            )
        }
    }

    /// What the last identify (or ad-ids call) told the server about tracking
    /// permission. `nil` until identify has succeeded once; `.some(nil)` means
    /// "sent, and the app had not asked yet".
    private var lastSentTracking: Bool?? = nil

    /// The tracking prompt is answered while the app is in the BACKGROUND as
    /// far as iOS is concerned (the system alert resigns it), so coming back to
    /// the front is the moment to notice. Only a changed answer is sent: a
    /// person who taps Allow during onboarding and pays a minute later has
    /// their payment reported with the id they just allowed.
    private func reportAdIdentifiersIfChanged() {
        guard let last = lastSentTracking else { return }
        let ids = AdIdentifiers.current()
        guard last != ids.trackingAllowed else { return }
        lastSentTracking = .some(ids.trackingAllowed)
        log("ad ids changed", ["tracking_allowed": ids.trackingAllowed as Any])
        var payload: [String: Any] = ["campaign_id": campaignId, "device_id": deviceId]
        for (key, value) in ids.payload { payload[key] = value }
        queue.enqueue(endpoint: "\(apiUrl)/api/v1/mobile/ad-ids", payload: payload)
    }

    /// Report one purchase to the app's ad networks, from the paywall, right
    /// after it succeeds. See `Affiliateo.purchase` for the full doc.
    public func purchase(
        transactionId: String,
        productId: String,
        price: Decimal,
        currency: String,
        kind: PurchaseKind = .subscription
    ) {
        if isOptedOut { return }
        let txId = transactionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txId.isEmpty, txId.count <= 200 else { return }
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3 else { return }
        log("purchase", ["transaction": txId, "product": productId, "price": price, "currency": code])
        var payload: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "transaction_id": txId,
            "product_id": productId,
            // A string, so a Decimal never turns into 59.989999999999995.
            "price": NSDecimalNumber(decimal: price).stringValue,
            "currency": code,
            "kind": kind.rawValue,
            "platform": "ios",
        ]
        // The ids as they are NOW: the prompt is often answered moments before
        // the paywall, after this launch's identify.
        for (key, value) in AdIdentifiers.current().payload { payload[key] = value }
        queue.enqueue(endpoint: "\(apiUrl)/api/v1/mobile/purchase", payload: payload)
        // The paywall is often the last screen before the person leaves; do
        // not wait for the timer.
        Task { await queue.flush() }
    }

    @objc private func appDidBecomeActive() {
        if isOptedOut { return }
        // Re-read the RevenueCat id, but only once we know `shared` is safe to
        // touch (see revenueCatShared()). Sign-in typically lands after our
        // first read, swapping the anonymous placeholder for the real id.
        if revenueCatReachable { reportRevenueCatAppUserId() }
        reportAdIdentifiersIfChanged()
        // Route through the queue so foreground pings survive a flaky
        // network the way regular page/track events do. The server's
        // start_mobile_session RPC is idempotent so a duplicate from a
        // queue retry just no-ops.
        let event: [String: Any] = [
            "type": EventType.sessionStart.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            // Belt and braces: the session RPC above already no-ops on a
            // replay, but stamping every event keeps one rule to reason
            // about rather than a per-type exception.
            "event_id": UUID().uuidString.lowercased(),
        ]
        queue.enqueue(
            endpoint: "\(apiUrl)/api/v1/mobile/event",
            payload: [
                "campaign_id": campaignId,
                "device_id": deviceId,
                "events": [event],
            ]
        )
    }

    // MARK: Live Chat (4.14.0)

    /// What Live Chat (Chat.swift) needs to know about this install. The ids
    /// are labels for the business's inbox, and the chat page leaves them out
    /// while opted out.
    func chatEnv() -> ChatRules.Env {
        ChatRules.Env(
            appId: campaignId,
            apiUrl: apiUrl,
            deviceId: deviceId,
            visitorId: state.visitorId,
            userId: userId,
            optedOut: isOptedOut,
            debug: debug
        )
    }

    func chatLog(_ msg: String) {
        log("chat: \(msg)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Persist any in-flight queue state and stop background timers.
        // Anything still queued stays on disk for the next launch.
        queue.shutdown()
    }
}

/// Resumes a continuation once, whichever caller comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

// MARK: - Static helpers

/// Top-level namespace for firing screen_view / custom events without
/// threading `@EnvironmentObject var affiliateo: AffiliateoManager` through
/// every view. No-op if `AffiliateoProvider` hasn't been mounted yet.
public enum Affiliateo {
    /// Fire a screen_view event. Call from `.onAppear` or `viewDidAppear`.
    public static func page(_ screenName: String, metadata: [String: Any]? = nil) {
        AffiliateoManager.shared?.page(screenName, metadata: metadata)
    }

    /// Fire a custom event with arbitrary name + metadata.
    public static func track(_ eventName: String, metadata: [String: Any]? = nil) {
        AffiliateoManager.shared?.track(eventName, metadata: metadata)
    }

    /// Say who is signed in. Call after sign-in. Pass `email` for free access:
    /// only its SHA-256 is sent, never the address. See
    /// `AffiliateoManager.identify` for the full doc.
    public static func identify(_ userId: String, email: String? = nil) {
        AffiliateoManager.shared?.identify(userId, email: email)
    }

    /// Whether the app owner gave the signed-in person free access (4.12.0).
    /// Never throws. Before `AffiliateoProvider` is up it answers from the
    /// phone's saved answer. See `AffiliateoManager.freeAccess` for the full
    /// doc.
    ///
    /// ```swift
    /// if await Affiliateo.freeAccess().active { unlock() }
    /// ```
    public static func freeAccess() async -> AffiliateoFreeAccess {
        guard let manager = AffiliateoManager.shared else {
            return FreeAccessCache.offlineAnswer(FreeAccessCache.load(), now: Date())
        }
        return await manager.freeAccess()
    }

    /// Report the host app's RevenueCat App User ID so an app owner can grant
    /// this affiliate complimentary access from their Affiliateo dashboard.
    /// See `AffiliateoManager.setRevenueCatUser` for the full doc.
    public static func setRevenueCatUser(_ appUserId: String) {
        AffiliateoManager.shared?.setRevenueCatUser(appUserId)
    }

    /// The user signed out. The device starts over as anonymous; tracking
    /// carries on. See `AffiliateoManager.logout` for the full doc.
    public static func logout() {
        AffiliateoManager.shared?.logout()
    }

    /// The same as `logout()` since 4.11.0. See `AffiliateoManager.reset`.
    public static func reset() {
        AffiliateoManager.shared?.reset()
    }

    /// Stop tracking on this device. Persistent across app restarts.
    /// Use for GDPR/CCPA "Don't track me" consent.
    public static func optOut() {
        AffiliateoManager.shared?.optOut()
    }

    /// Re-enable tracking after a previous optOut(). Host should
    /// reinitialize the provider to fully resume.
    public static func optIn() {
        AffiliateoManager.shared?.optIn()
    }

    /// Force-drain the event queue immediately. Best-effort. See
    /// `AffiliateoManager.flush` for full doc.
    public static func flush() async {
        await AffiliateoManager.shared?.flush()
    }

    // MARK: Live Chat (4.14.0)

    /// Show the Live Chat bubble on every screen (4.14.0). People tap it to
    /// chat with you in real time; you answer from the Live Chat inbox in
    /// your Affiliateo dashboard. It shows only while Live Chat is switched on
    /// for this app there, and remembers where the person dragged it.
    ///
    /// ```swift
    /// AffiliateoProvider(appId: "YOUR_APP_ID") {
    ///     ContentView()
    ///         .onAppear { Affiliateo.showChatBubble() }
    /// }
    /// ```
    ///
    /// Nothing shows until the app calls this or `openChat()`, so the App
    /// Store reviewer sees every feature the app has. iPhone and iPad only.
    public static func showChatBubble() {
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.showBubble() }
        #endif
    }

    /// Keep the chat bubble above your app's own bottom bar (4.15.0): a tab
    /// bar or a floating button. The bubble starts this many points above the
    /// bottom of the safe area and is never dragged below them.
    ///
    /// ```swift
    /// Affiliateo.setChatBubblePadding(bottom: 72)
    /// ```
    public static func setChatBubblePadding(bottom: CGFloat) {
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.setBottomPadding(bottom) }
        #endif
    }

    /// Take the chat bubble away again (4.14.0).
    public static func hideChatBubble() {
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.hideBubble() }
        #endif
    }

    /// Open the chat from your own button (4.14.0), over whatever is on
    /// screen. Does nothing while Live Chat is off for this app (with
    /// `debug: true` it says so in the console).
    ///
    /// ```swift
    /// Button("Chat with us") { Affiliateo.openChat() }
    /// ```
    public static func openChat() {
        #if os(iOS)
        Task { @MainActor in LiveChat.shared.open() }
        #endif
    }

    /// Whether Live Chat is on for this app right now (4.14.0), to show or
    /// hide your own "Chat with us" button. Never throws: no answer is false.
    public static func chatAvailable() async -> Bool {
        #if os(iOS)
        return await LiveChat.shared.available()
        #else
        return false
        #endif
    }

    /// Report a purchase to the ad networks this app sends its sales to.
    /// Call it on your paywall, right after a purchase succeeds.
    ///
    /// ```swift
    /// // RevenueCat
    /// let result = try await Purchases.shared.purchase(package: package)
    /// if !result.userCancelled, let transaction = result.transaction {
    ///     Affiliateo.purchase(
    ///         transactionId: transaction.transactionIdentifier,
    ///         productId: transaction.productIdentifier,
    ///         price: package.storeProduct.price,
    ///         currency: package.storeProduct.currencyCode ?? "USD"
    ///     )
    /// }
    /// ```
    ///
    /// - `transactionId`: the App Store's id for this payment. Affiliateo keys
    ///   the report on it, so a payment your payment provider ALSO reports
    ///   (RevenueCat, Apple, Adapty connected in Affiliateo) goes to each
    ///   network once.
    /// - `price` and `currency`: what the person paid, in normal units (59.99).
    /// - `kind`: `.subscription` (the default) or `.oneTime`.
    ///
    /// Optional when a payment provider is connected to the app in Affiliateo:
    /// first payments are then reported without it. What this call adds is
    /// speed and the phone's own network address, which the networks match
    /// on. Nothing here records a sale or moves money.
    public static func purchase(
        transactionId: String,
        productId: String,
        price: Decimal,
        currency: String,
        kind: PurchaseKind = .subscription
    ) {
        AffiliateoManager.shared?.purchase(
            transactionId: transactionId,
            productId: productId,
            price: price,
            currency: currency,
            kind: kind
        )
    }

    #if canImport(StoreKit)
    /// The same, straight from a StoreKit 2 transaction, for apps that sell
    /// without RevenueCat:
    ///
    /// ```swift
    /// if case .success(.verified(let transaction)) = try await product.purchase() {
    ///     Affiliateo.purchase(transaction)
    ///     await transaction.finish()
    /// }
    /// ```
    @available(iOS 15.0, macOS 12.0, *)
    public static func purchase(_ transaction: StoreKit.Transaction) {
        guard let price = transaction.price else { return }
        let currency: String?
        if #available(iOS 16.0, macOS 13.0, *) {
            currency = transaction.currency?.identifier
        } else {
            currency = transaction.currencyCode
        }
        guard let currency else { return }
        purchase(
            transactionId: String(transaction.id),
            productId: transaction.productID,
            price: price,
            currency: currency,
            kind: transaction.productType == .autoRenewable ? .subscription : .oneTime
        )
    }
    #endif
}

// MARK: - SwiftUI screen helper

/// One-line screen tracking modifier. Replaces the old pattern of:
///   ContentView()
///       .onAppear { Affiliateo.page("HomeScreen") }
///
/// With:
///   ContentView()
///       .trackedScreen("HomeScreen")
///
/// Mirrors @affiliateo/react-native's useAffiliateoScreen hook and
/// the usual analytics screen hooks. The metadata closure is fired
/// lazily so a screen that builds metadata from runtime state (a user
/// tier, an A/B variant) doesn't pay the cost on every render.
public extension View {
    /// Fire a screen_view event when this view first appears.
    /// Idempotent across re-renders: only the first `.onAppear` call
    /// per view instance fires.
    func trackedScreen(_ screenName: String, metadata: [String: Any]? = nil) -> some View {
        modifier(TrackedScreenModifier(screenName: screenName, metadata: metadata))
    }
}

private struct TrackedScreenModifier: ViewModifier {
    let screenName: String
    let metadata: [String: Any]?
    // Track-fired flag scoped to the view instance so re-renders don't
    // re-fire. SwiftUI's @State semantics make this stable across body
    // recomputations but reset on view-identity changes (e.g. NavigationStack
    // pushing a fresh screen of the same type, which is correctly counted
    // as a separate visit).
    @State private var fired = false

    func body(content: Content) -> some View {
        content.onAppear {
            if !fired {
                fired = true
                Affiliateo.page(screenName, metadata: metadata)
            }
        }
    }
}
