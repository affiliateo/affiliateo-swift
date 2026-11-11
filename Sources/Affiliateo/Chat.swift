#if os(iOS)
import UIKit
import UserNotifications
import WebKit

/// Live Chat (4.14.0): the app's users chat in real time with the business,
/// which answers from the Live Chat inbox in its Affiliateo dashboard.
///
///     Affiliateo.showChatBubble()   the bubble on the app's pages (what is presented over them covers it)
///     Affiliateo.openChat()         or open it from your own button
///
/// Nothing shows until the app calls one of them: an app must not grow a
/// visible feature its App Store reviewer never saw. And nothing shows while
/// the business has the chat switched off for this app, which the SDK asks
/// the server about.
///
/// The owner's choices come with the config (ChatRules.Bubble): the corner the
/// bubble starts in, its size, the screens it shows on (matched against the
/// name the app last passed to `Affiliateo.page(_:)`), and a greeting that
/// counts as one unread message until the chat is first opened. While the app
/// is in front and the chat is closed, a socket on the thread keeps the red
/// number live. While the app shows the bubble and is in front, the app's own
/// channel brings the owner's on/off switch and the team's Online switches at
/// once (a `config` frame, applied as a fresh config read is).
///
/// 4.17.0: the bubble wiggles every so often (the owner's seconds, or the
/// app's own with setChatBubbleWiggle; one smooth 0.9 s wiggle of the whole
/// bubble, ChatRules.wiggleAngle), and a reply shows as a notification,
/// like a message. The app hands over its push token (setChatPushToken), asks
/// the SDK how to show a notification that arrives while it is open
/// (chatNotificationPresentation) and passes it the taps
/// (handleChatNotification), which open the chat over whatever is on screen.
/// Without a registered push token the SDK posts the notification itself
/// while the app is in front, and once the app says notifications are
/// allowed (chatNotificationsAllowed) a greeting nobody has seen goes out as
/// one too, once.
///
/// The visitor's key to their thread (a token the server hands out with their
/// first message) is kept in the Keychain, on this phone only (4.15.4, review
/// S18; ChatTokenStore): never in a backup, and deleting the app still starts
/// a new thread, which is what the server expects. logout() drops it
/// (4.14.2), so the next person on the phone starts a new thread too.
@MainActor
final class LiveChat {
    static let shared = LiveChat()

    /// The last config, from a read or the app channel (internal for the tests).
    private(set) var config: ChatRules.Config?
    private var configCheckedAt: Date?
    private var configTask: Task<ChatRules.Config, Never>?
    private var unreadCheckedAt: Date?
    private var unread = 0
    /// Online for this person alone (their own affiliate counts), from the unread check, beside the config's.
    private var visitorOnline = false
    /// The greeting nobody on this phone has seen yet: one unread message.
    private var greetingPending = false
    /// The name the app last passed to page(_:).
    private var currentScreen: String?
    private var wantsBubble = false
    private var wantsOpen = false
    private var observing = false
    private var inFront = true
    /// Internal for the tests.
    var bubble: ChatBubbleView?
    private weak var screen: ChatViewController? {
        didSet { ChatOnScreen.set(screen != nil) }
    }
    /// Points the app keeps free above the bottom safe area (its tab bar or
    /// floating button), set with Affiliateo.setChatBubblePadding(bottom:).
    private var bottomPadding: CGFloat = 0
    /// The app's own look for the bubble (setChatBubbleLook), over the dashboard's.
    private var look = ChatRules.BubbleLook()
    /// The app's own message box text (setChatPlaceholder), over the dashboard's.
    private var placeholder: String?

    // The live socket on the thread, for the red number.
    private var socket: URLSessionWebSocketTask?
    private var socketTries = 0
    private var socketRetry: Task<Void, Never>?
    private var socketPing: Timer?

    // The app channel: the owner's switch and the team's Online switches, live.
    private var appSocket: URLSessionWebSocketTask?
    private var appTries = 0
    private var appRetry: Task<Void, Never>?
    private var appPing: Timer?
    /// The server refused the app channel (no such app, or the chat is off):
    /// not tried again until a config read says the chat is on.
    private var appRefused = false

    // The wiggle (4.17.0).
    /// The app's own seconds between two wiggles (setChatBubbleWiggle), 0 for
    /// off, over the dashboard's; nil while the app made no choice.
    private var wiggleOverride: Int?
    private var wiggleTimer: Timer?
    /// The seconds the running timer was started with; 0 while none runs.
    private var wiggleEvery = 0

    // Notifications (4.17.0).
    /// Apple's push token for this install, hex, as the app handed it over.
    private var pushToken: String?
    private var pushBusy = false
    private var pushAgain = false
    /// The registration the server has answered in this launch (whatever it
    /// said): not sent again until something in it changes.
    private var pushAnswered: ChatRules.PushDevice?
    /// When a request last got no answer at all: the next waits a while.
    private var pushTriedAt: Date?
    /// The server answered a "forget this phone" with an error: left until
    /// the next launch.
    private var pushForgetFailed = false
    /// The app said notifications are allowed (chatNotificationsAllowed).
    private var allowed = false
    private var greetingBusy = false
    /// A tapped notification's chat, waiting for a screen to open on.
    private var pendingOpen = false
    /// Tries left for it while the app is still launching or the screen on
    /// top is busy.
    private var openRetries = 0

    private init() {}

    /// Nil until AffiliateoProvider has made its manager.
    private var env: ChatRules.Env? { AffiliateoManager.shared?.chatEnv() }

    private func log(_ msg: String) {
        AffiliateoManager.shared?.chatLog(msg)
    }

    // MARK: What the app calls

    func showBubble() {
        wantsBubble = true
        observeForeground()
        // Placed once AffiliateoProvider starts (managerStarted).
        guard let env else { return }
        // At once from the last answer this phone kept, then checked with the
        // server (turned off there, it goes away again).
        if config == nil, let data = UserDefaults.standard.data(forKey: ChatRules.configKey(env.appId)) {
            let saved = ChatRules.parseConfig(data)
            if saved.enabled {
                config = saved
                placeBubble()
            }
        }
        Task {
            await refreshConfig(force: configCheckedAt == nil)
            placeBubble()
            await refreshUnread(force: true)
        }
    }

    func setLook(_ next: ChatRules.BubbleLook) {
        look = next
        placeBubble()
    }

    func setPlaceholder(_ text: String?) {
        placeholder = text
    }

    func setBottomPadding(_ points: CGFloat) {
        // Any height (4.16.3; 400 at most before): clamp(_:) keeps the bubble
        // inside the window, so an app can lift it up beside its content.
        bottomPadding = max(0, points)
        bubble?.bottomPadding = bottomPadding
        bubble?.place()
    }

    func hideBubble() {
        wantsBubble = false
        removeBubble()
        syncAppChannel()
    }

    func open() {
        observeForeground()
        guard env != nil else {
            wantsOpen = true
            log("openChat waits for AffiliateoProvider")
            return
        }
        Task {
            guard await refreshConfig(force: false).enabled else {
                log("openChat skipped, the chat is off for this app")
                return
            }
            presentChat()
        }
    }

    func available() async -> Bool {
        guard env != nil else { return false }
        return await refreshConfig(force: false).enabled
    }

    /// AffiliateoProvider started: do what the app asked for before it did.
    func managerStarted() {
        if wantsBubble { showBubble() }
        if wantsOpen {
            wantsOpen = false
            open()
        }
        // What the app asked for about notifications before it did (4.17.0).
        tryPendingOpen()
        if allowed { notificationsAllowed() }
        if pushToken != nil { pushChanged() } else { syncPush() }
    }

    /// The app called page(_:): the owner's screen rules follow it.
    func screenChanged(_ name: String) {
        guard !name.isEmpty, name != currentScreen else { return }
        currentScreen = name
        if wantsBubble, config != nil { placeBubble() }
    }

    /// The person signed out (logout(), which has already dropped their token
    /// from the Keychain). Their red number, socket and open chat go too, so
    /// whoever signs in next starts a new thread. The bubble's place and the
    /// greeting seen belong to the phone, not the person: they stay.
    func forget() {
        stopSocket()
        unreadCheckedAt = nil
        visitorOnline = false
        setUnread(0)
        // A token the closing page hands over late is not kept.
        screen?.onToken = nil
        screen?.dismiss(animated: true)
        // The server forgets this phone too (4.17.0): a reply to the last
        // person's thread must not show up for whoever holds the phone
        // next. It is registered again once the next person starts a thread
        // of their own.
        if let env {
            let defaults = UserDefaults.standard
            if let token = savedPush(env.appId)?.token ?? pushToken {
                defaults.set(token, forKey: ChatRules.pushForgetKey(env.appId))
            }
            defaults.removeObject(forKey: ChatRules.pushKey(env.appId))
            defaults.set(true, forKey: ChatRules.pushHeldKey(env.appId))
            // Whatever the server answered before was about the last person.
            pushAnswered = nil
            syncPush()
            // Nor do their notifications stay in the list.
            clearNotices()
        }
        // Nothing of their chat stays in web storage (4.15.1): the chat page
        // runs in a private store now, and whatever an older version left in
        // the shared one for Affiliateo's host goes. Cookies are left alone.
        if let host = env.flatMap({ URL(string: $0.apiUrl)?.host }) {
            Self.clearWebStorage(host: host)
        }
    }

    /// Removes the chat page's local, session and IndexedDB storage for
    /// Affiliateo's host from the shared web data store.
    private static func clearWebStorage(host: String) {
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
        ]
        store.fetchDataRecords(ofTypes: types) { records in
            let chat = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            guard !chat.isEmpty else { return }
            store.removeData(ofTypes: types, for: chat) {}
        }
    }

    // MARK: The server

    /// Whether the business has the chat on for this app. A network failure
    /// keeps the last answer; anything but a 200 reads as off.
    @discardableResult
    private func refreshConfig(force: Bool) async -> ChatRules.Config {
        if let configTask { return await configTask.value }
        if !force, let config, let at = configCheckedAt, Date().timeIntervalSince(at) < ChatRules.configMaxAge {
            return config
        }
        guard let env, let url = URL(string: "\(env.apiUrl)/api/live-chat/config?app=\(ChatRules.encode(env.appId))") else {
            return config ?? .off
        }
        let request = URLRequest(url: url, cachePolicy: force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        let task = Task<ChatRules.Config, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .off }
                UserDefaults.standard.set(data, forKey: ChatRules.configKey(env.appId))
                return ChatRules.parseConfig(data)
            } catch {
                self.log("config check failed (network)")
                return self.config ?? .off
            }
        }
        configTask = task
        let answer = await task.value
        configTask = nil
        config = answer
        configCheckedAt = Date()
        noteGreeting(answer, appId: env.appId)
        // The chat is on: the app channel may be tried again.
        if answer.enabled { appRefused = false }
        configArrived()
        return answer
    }

    /// A config came in (a read, or the app channel): what waits for one
    /// goes on (4.17.0): the push token's registration, the greeting's
    /// notification and the wiggle's pace.
    private func configArrived() {
        syncPush()
        notifyGreetingIfDue()
        syncWiggle()
    }

    /// Somebody who already wrote has seen the greeting.
    private func noteGreeting(_ answer: ChatRules.Config, appId: String) {
        if answer.enabled, let id = answer.bubble.greetingId, storedToken(appId) == nil {
            greetingPending = UserDefaults.standard.string(forKey: ChatRules.greetingKey(appId)) != id
        } else {
            greetingPending = false
        }
    }

    /// A `config` frame from the app channel: kept as a fresh config read
    /// would be (the current config, the phone's saved answer, its age) and
    /// applied the same way. Off, the bubble goes and an open chat closes.
    func receivedAppFrame(_ text: String) {
        guard let frame = ChatRules.parseAppFrame(text) else { return }
        let answer = frame.config
        if let env {
            UserDefaults.standard.set(frame.saved, forKey: ChatRules.configKey(env.appId))
            noteGreeting(answer, appId: env.appId)
        }
        config = answer
        configCheckedAt = Date()
        if !answer.enabled {
            log("the chat was switched off for this app")
            screen?.dismiss(animated: true)
        }
        placeBubble()
        paintBubble()
        configArrived()
    }

    /// Replies the person has not seen, for the red number on the bubble.
    private func refreshUnread(force: Bool) async {
        guard let env, let token = storedToken(env.appId) else { return }
        if !force, let at = unreadCheckedAt, Date().timeIntervalSince(at) < ChatRules.unreadMaxAge { return }
        unreadCheckedAt = Date()
        guard let url = URL(string: "\(env.apiUrl)/api/live-chat/unread") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let count = ChatRules.parseUnread(data),
              // A sign-out while this was on its way: the count was the last person's.
              storedToken(env.appId) == token
        else { return }
        visitorOnline = ChatRules.parseUnreadOnline(data) ?? false
        // An open chat has just shown them everything.
        if screen == nil { setUnread(count) } else { paintBubble() }
    }

    private func storedToken(_ appId: String) -> String? {
        ChatTokenStore.standard.token(appId: appId)
    }

    private func observeForeground() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in LiveChat.shared.cameToFront() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in LiveChat.shared.wentAway() }
        }
    }

    /// The owner may have switched the chat on or off while the app was away,
    /// and a reply may have come in.
    private func cameToFront() {
        inFront = true
        // A tapped notification's chat, and a push token the server has not
        // confirmed yet (4.17.0).
        tryPendingOpen()
        syncPush()
        guard wantsBubble, env != nil else { return }
        Task {
            await refreshConfig(force: false)
            placeBubble()
            await refreshUnread(force: false)
        }
    }

    private func wentAway() {
        inFront = false
        stopSocket()
        syncAppChannel()
        syncWiggle()
    }

    private func setUnread(_ count: Int) {
        unread = count
        paintBubble()
    }

    private func paintBubble() {
        bubble?.update(unread: unread + (greetingPending ? 1 : 0), online: (config?.online ?? false) || visitorOnline)
    }

    // MARK: The bubble

    private func placeBubble() {
        // The wiggle runs only while the bubble is on screen (4.17.0).
        defer { syncWiggle() }
        syncAppChannel()
        guard ChatRules.showsBubble(wanted: wantsBubble, config: config), let env, let config else {
            removeBubble()
            return
        }
        let style = ChatRules.applying(look, to: config.bubble)
        guard screen == nil, ChatRules.bubbleShowsOn(mode: style.pageMode, rules: style.pageRules, place: currentScreen) else {
            bubble?.isHidden = true
            stopSocket()
            return
        }
        // No window yet (the app is still launching): the next foreground places it.
        guard let window = Self.hostWindow() else { return }
        // An iPhone gets the owner's phone size ("auto" makes it smaller), an iPad the other.
        let size = CGFloat(UIDevice.current.userInterfaceIdiom == .phone ? style.sizePhone : style.size)
        let glass = style.style == "glass"
        if let existing = bubble, existing.size != size || existing.glass != glass || existing.colors != (style.color, style.iconColor) {
            existing.removeFromSuperview()
            bubble = nil
        }
        let view = bubble ?? ChatBubbleView(appId: env.appId, size: size, glass: glass, color: style.color, iconColor: style.iconColor) { LiveChat.shared.open() }
        bubble = view
        view.position = style.position
        view.bottomPadding = bottomPadding
        Self.keepOnPages(view, in: window)
        view.place()
        view.isHidden = false
        paintBubble()
        startSocket()
    }

    /// THE BUBBLE IS FOR THE APP'S PAGES (4.15.2, review E1): it sits just
    /// above the app's pages and below anything presented over them, so a
    /// sheet, a full-screen cover or an alert covers it. Every path that
    /// shows it again (a launch, the app coming back to the front, page(_:),
    /// a new look) comes through here; it used to bring itself to the front
    /// of the window and land on top of whatever was presented.
    ///
    /// The pages are the window's own subview that holds the root view: the
    /// root view itself on older systems, its container on iOS 26 and later
    /// (window, UITransitionView, UIDropShadowView, root view). A presented
    /// screen gets a container of its own, added to the window above that
    /// one. 4.15.2 only looked for the root view right in the window, missed
    /// it there, and put the bubble under the app, out of sight (4.15.3).
    static func keepOnPages(_ view: UIView, in window: UIWindow) {
        guard let root = window.rootViewController?.view, let pages = windowSubview(holding: root, in: window) else {
            // No root view in the window yet: the lowest place there is, until
            // the next placement (the config arriving, a page, the app coming
            // back) finds the pages.
            if view.superview !== window { window.insertSubview(view, at: 0) }
            return
        }
        let subviews = window.subviews
        if view.superview === window,
           let mine = subviews.firstIndex(of: view),
           let pagesIndex = subviews.firstIndex(of: pages),
           mine == pagesIndex + 1 {
            return
        }
        window.insertSubview(view, aboveSubview: pages)
    }

    /// The window's own subview that `view` is in (the view itself when it is
    /// right in the window), or nil when it is not in this window.
    static func windowSubview(holding view: UIView, in window: UIWindow) -> UIView? {
        var current: UIView? = view
        while let candidate = current, candidate.superview !== window {
            current = candidate.superview
        }
        return current
    }

    private func removeBubble() {
        stopSocket()
        bubble?.removeFromSuperview()
        bubble = nil
        syncWiggle()
    }

    // MARK: The wiggle (4.17.0)

    /// The app's own seconds between two wiggles (0 for off), over the
    /// dashboard's.
    func setWiggle(_ seconds: Int) {
        wiggleOverride = seconds
        syncWiggle()
    }

    /// Runs the wiggle's timer while the bubble is on screen, the chat is
    /// closed and the app is in front, at the app's own pace or the
    /// dashboard's; stops it otherwise.
    private func syncWiggle() {
        let shown = bubble?.isHidden == false && screen == nil && inFront
        // Hidden, behind the opening chat or out of sight: a wiggle that is
        // playing is cut, back to rest.
        if !shown { bubble?.stopWiggle() }
        let seconds = shown ? ChatRules.wiggleEvery(override: wiggleOverride, config: config) : 0
        guard seconds != wiggleEvery else { return }
        wiggleTimer?.invalidate()
        wiggleTimer = nil
        wiggleEvery = seconds
        guard seconds > 0 else { return }
        wiggleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { _ in
            Task { @MainActor in LiveChat.shared.wiggleNow() }
        }
    }

    /// One tick of the timer: the bubble wiggles once, unless something
    /// speaks against it right now (ChatRules.wigglesNow).
    private func wiggleNow() {
        guard let bubble else { return }
        let wiggles = ChatRules.wigglesNow(
            every: wiggleEvery,
            bubbleShown: !bubble.isHidden && bubble.window != nil,
            chatOpen: screen != nil,
            inFront: inFront && UIApplication.shared.applicationState == .active,
            dragging: bubble.isDragging,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        if wiggles { bubble.wiggle() }
    }

    // MARK: The live red number

    /// A socket on the thread while there is one, the bubble is on screen,
    /// the app is in front and the chat is closed (the chat screen has its own).
    private func startSocket() {
        guard socket == nil, socketRetry == nil, inFront, screen == nil, bubble?.isHidden == false,
              let env, let token = storedToken(env.appId),
              let url = URL(string: env.apiUrl.replacingOccurrences(of: "http", with: "ws", options: .anchored)
                  + "/api/live-chat/stream")
        else { return }
        // The key goes in the header, never in the address, where it would
        // land in the server's request logs (4.15.2, review E3).
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        socketPing = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak task] _ in
            task?.send(.string("ping")) { _ in }
        }
        Task { await listen(task) }
    }

    private func listen(_ task: URLSessionWebSocketTask) async {
        while socket === task {
            do {
                let message = try await task.receive()
                socketTries = 0
                guard case .string(let text) = message, text != "pong",
                      let data = text.data(using: .utf8),
                      let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      frame["kind"] as? String == "live_chat"
                else { continue }
                let event = frame["event"] as? String
                if let message = ChatRules.teamMessage(frame) {
                    setUnread(unread + 1)
                    // As a notification too, on a phone without a registered
                    // push token (4.17.0).
                    notifyMessage(message)
                } else if event == "read", frame["by"] as? String == "visitor" {
                    setUnread(0)
                }
            } catch {
                guard socket === task else { return }
                dropSocket()
                socketTries += 1
                let delay = min(60, pow(2, Double(min(socketTries, 6))))
                socketRetry = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self.socketRetry = nil
                    self.startSocket()
                }
                return
            }
        }
    }

    private func dropSocket() {
        socketPing?.invalidate()
        socketPing = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func stopSocket() {
        socketRetry?.cancel()
        socketRetry = nil
        dropSocket()
    }

    // MARK: The app channel

    /// Opens or closes the app channel to match ChatRules.appChannelWanted.
    /// The chat sheet may be open or closed, and the bubble hidden on this
    /// screen by the page rules: the channel stays while the app shows it.
    private func syncAppChannel() {
        if env != nil, ChatRules.appChannelWanted(wantsBubble: wantsBubble, inFront: inFront, config: config, refused: appRefused) {
            startAppChannel()
        } else {
            stopAppChannel()
        }
    }

    private func startAppChannel() {
        guard appSocket == nil, appRetry == nil, let env,
              let url = ChatRules.appChannelURL(apiUrl: env.apiUrl, appId: env.appId)
        else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        appSocket = task
        task.resume()
        appPing = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak task] _ in
            task?.send(.string("ping")) { _ in }
        }
        Task { await listenApp(task) }
    }

    private func listenApp(_ task: URLSessionWebSocketTask) async {
        while appSocket === task {
            do {
                let message = try await task.receive()
                appTries = 0
                guard case .string(let text) = message, text != "pong" else { continue }
                receivedAppFrame(text)
            } catch {
                guard appSocket === task else { return }
                let status = (task.response as? HTTPURLResponse)?.statusCode
                dropAppChannel()
                if ChatRules.refusesAppChannel(status: status) {
                    appRefused = true
                    log("app channel refused (\(status ?? 0))")
                    return
                }
                appTries += 1
                let delay = ChatRules.appChannelDelay(tries: appTries, jitter: Double.random(in: 0...1))
                appRetry = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.appRetry = nil
                    self.syncAppChannel()
                }
                return
            }
        }
    }

    private func dropAppChannel() {
        appPing?.invalidate()
        appPing = nil
        appSocket?.cancel(with: .goingAway, reason: nil)
        appSocket = nil
    }

    private func stopAppChannel() {
        appRetry?.cancel()
        appRetry = nil
        appTries = 0
        dropAppChannel()
    }

    // MARK: The chat screen

    private func presentChat() {
        guard screen == nil else {
            openRetries = 0
            return
        }
        guard let env, let window = Self.hostWindow(), let presenter = Self.topController(window.rootViewController) else {
            log("openChat: no screen to show the chat on yet")
            retryOpenLater()
            return
        }
        let dark = presenter.traitCollection.userInterfaceStyle == .dark
        guard let url = ChatRules.chatURL(
            env: env,
            token: storedToken(env.appId),
            platform: "ios",
            language: Locale.preferredLanguages.first ?? "en",
            theme: dark ? "dark" : "light",
            sendColor: look.sendColor,
            placeholder: placeholder
        ) else { return }
        let appId = env.appId
        let controller = ChatViewController(url: url, apiUrl: env.apiUrl, appId: appId, dark: dark, inspectable: env.debug)
        // A key the page hands over is saved only while nobody signed out (or
        // switched person) since this screen opened (4.15.1).
        let openedAt = ChatSignOuts.current
        controller.onToken = { token in
            guard ChatSignOuts.current == openedAt else { return }
            ChatTokenStore.standard.save(token, appId: appId)
            // A thread of their own: after a sign-out the phone may be
            // registered for its replies again (4.17.0).
            LiveChat.shared.syncPush()
        }
        controller.onRead = { LiveChat.shared.setUnread(0) }
        controller.onClosed = { LiveChat.shared.chatClosed() }
        screen = controller
        // No wiggle while the chat slides up over the bubble.
        syncWiggle()
        // They see the greeting now; a new one counts again.
        if let id = config?.bubble.greetingId { UserDefaults.standard.set(id, forKey: ChatRules.greetingKey(appId)) }
        greetingPending = false
        // A sheet that slides up over the app (4.15.0), with its handle; pulled
        // down, or the page's close button, closes it.
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        // The bubble and its socket go once the sheet is really up (4.15.2,
        // review E11). UIKit refuses a presentation silently while another one
        // is moving, and the bubble used to stay hidden until the next page(_:)
        // or foreground; such a chat is let go below and the bubble stays.
        presenter.present(controller, animated: true) { [weak self, weak controller] in
            guard let self, let controller, self.screen === controller else { return }
            self.stopSocket()
            self.bubble?.isHidden = true
            self.syncWiggle()
            self.openRetries = 0
            // They are reading the chat now: its notifications leave the
            // list, as a conversation's do in Messages (4.17.0).
            self.clearNotices()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak controller] in
            guard let self, let controller, self.screen === controller, controller.presentingViewController == nil else { return }
            self.log("openChat: the screen on top was busy presenting; try again")
            self.screen = nil
            self.placeBubble()
            self.retryOpenLater()
        }
    }

    /// A tapped notification's chat is tried again by itself (4.17.0): the
    /// app may still be launching, or the screen on top was busy presenting.
    /// A plain openChat() is left to the app, as before.
    private func retryOpenLater() {
        guard openRetries > 0 else { return }
        openRetries -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.screen == nil else { return }
            self.presentChat()
        }
    }

    private func chatClosed() {
        screen = nil
        setUnread(0)
        placeBubble()
    }

    // MARK: Notifications (4.17.0)

    /// The person tapped a chat notification (handleChatNotification): the
    /// chat opens over whatever is on screen, as openChat() does, once the
    /// app is in front with a screen to open it on. After a cold start that
    /// is a moment later, so the request is kept until then.
    func openFromNotification() {
        observeForeground()
        pendingOpen = true
        tryPendingOpen()
    }

    private func tryPendingOpen() {
        guard pendingOpen, env != nil, UIApplication.shared.applicationState == .active else { return }
        pendingOpen = false
        openRetries = 12
        Task {
            guard await refreshConfig(force: false).enabled else {
                openRetries = 0
                log("the notification's chat was skipped, the chat is off for this app")
                return
            }
            presentChat()
        }
    }

    /// The app says notifications are allowed (chatNotificationsAllowed): a
    /// greeting nobody on this phone has seen goes out as one, now or as
    /// soon as the config is here.
    func notificationsAllowed() {
        allowed = true
        observeForeground()
        // Before AffiliateoProvider: managerStarted comes back here.
        guard env != nil else { return }
        Task {
            await refreshConfig(force: false)
            notifyGreetingIfDue()
        }
    }

    /// Posts the greeting as ONE notification per greeting and install
    /// (ChatRules.greetingNoticeDue). The red 1 stays until the chat opens.
    private func notifyGreetingIfDue() {
        guard !greetingBusy, let env, let config else { return }
        let language = Locale.preferredLanguages.first ?? "en"
        let key = ChatRules.greetingNotifiedKey(env.appId)
        guard ChatRules.greetingNoticeDue(
            allowed: allowed,
            config: config,
            pending: greetingPending,
            notifiedId: UserDefaults.standard.string(forKey: key),
            chatOpen: screen != nil,
            language: language
        ), let id = config.bubble.greetingId, let greeting = ChatRules.greetingText(config, language: language)
        else { return }
        greetingBusy = true
        Task {
            defer { greetingBusy = false }
            // iOS has the last word; the SDK never asks for the permission itself.
            guard await Self.mayNotify(), screen == nil, greetingPending else { return }
            UserDefaults.standard.set(id, forKey: key)
            post(
                title: Self.noticeTitle(config),
                body: ChatRules.noticeBody(greeting, language: language),
                notice: ChatRules.Notice(app: env.appId, greetingId: id),
                identifier: "affiliateo-chat-greeting"
            )
        }
    }

    /// A team message came in on the socket: on a phone without a registered
    /// push token the SDK posts the notification itself
    /// (ChatRules.postsLocalNotice); a registered phone gets Affiliateo's push.
    private func notifyMessage(_ message: ChatRules.TeamMessage) {
        guard let env, ChatRules.postsLocalNotice(
            inFront: inFront && UIApplication.shared.applicationState == .active,
            chatOpen: screen != nil,
            pushRegistered: savedPush(env.appId) != nil
        ) else { return }
        let title = Self.noticeTitle(config)
        Task {
            guard await Self.mayNotify(), screen == nil else { return }
            post(
                title: title,
                body: ChatRules.noticeBody(message.body, language: Locale.preferredLanguages.first ?? "en"),
                notice: ChatRules.Notice(app: env.appId, conversationId: message.conversationId, messageId: message.id),
                identifier: "affiliateo-chat-" + (message.id ?? UUID().uuidString)
            )
        }
    }

    /// A notification of the SDK's own, with the look of Affiliateo's push:
    /// the Live Chat app's name, the words, the default sound.
    private func post(title: String, body: String, notice: ChatRules.Notice, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = ChatRules.noticeThread
        content.userInfo = ChatRules.noticeInfo(notice)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard error != nil else { return }
            Task { @MainActor in LiveChat.shared.log("a notification could not be posted") }
        }
    }

    /// The Live Chat app's name, else the app's own.
    private static func noticeTitle(_ config: ChatRules.Config?) -> String {
        if let name = config?.appName { return name }
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? ""
    }

    /// Whether iOS lets the app post notifications.
    private static func mayNotify() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// The chat's notifications leave the list (the chat is open, or the
    /// person signed out); the app's own stay.
    private func clearNotices() {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ours = delivered
                .filter { ChatRules.notice($0.request.content.userInfo) != nil }
                .map(\.request.identifier)
            if !ours.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ours) }
        }
    }

    // MARK: The push token (4.17.0)

    /// What the server last confirmed about this phone, kept across
    /// launches: while there is one, replies come as Affiliateo's push, and
    /// a sign-out knows which token the server is to forget.
    private func savedPush(_ appId: String) -> ChatRules.PushDevice? {
        UserDefaults.standard.data(forKey: ChatRules.pushKey(appId))
            .flatMap { try? JSONDecoder().decode(ChatRules.PushDevice.self, from: $0) }
    }

    /// Apple's push service for this build (ChatRules.apnsEnvironment).
    private static let pushEnvironment: String = {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        return ChatRules.apnsEnvironment(profile: profile, simulator: simulator, debugBuild: debugBuild)
    }()

    /// The app handed over its push token (setChatPushToken).
    func setPushToken(_ token: String) {
        pushToken = token
        observeForeground()
        // Before AffiliateoProvider: managerStarted comes back here.
        guard env != nil else { return }
        pushChanged()
    }

    /// The registration needs to know whether the chat is on for this app.
    private func pushChanged() {
        Task {
            await refreshConfig(force: false)
            syncPush()
        }
    }

    /// Brings the server in line with this phone, one request at a time: a
    /// phone to forget first (a sign-out, an opt-out), then the registration,
    /// once each launch and when it changed (ChatRules.pushRegistrationDue).
    func syncPush() {
        guard env != nil else { return }
        guard !pushBusy else {
            pushAgain = true
            return
        }
        pushBusy = true
        Task {
            await runPushSync()
            pushBusy = false
            if pushAgain {
                pushAgain = false
                syncPush()
            }
        }
    }

    private func runPushSync() async {
        guard let env else { return }
        let defaults = UserDefaults.standard
        let appId = env.appId
        // Opted out of tracking: the chat carries no device id from now on,
        // so the server forgets this phone.
        if env.optedOut, let saved = savedPush(appId) {
            defaults.set(saved.token, forKey: ChatRules.pushForgetKey(appId))
            defaults.removeObject(forKey: ChatRules.pushKey(appId))
            // Opting in again registers the phone again.
            pushAnswered = nil
        }
        // A phone to forget goes first, so it can never undo a registration
        // made after it.
        if let old = defaults.string(forKey: ChatRules.pushForgetKey(appId)) {
            guard !pushForgetFailed, pushMayTry() else { return }
            switch await sendPush("DELETE", ["app": appId, "token": old], env) {
            case .ok, .notTaken:
                if defaults.string(forKey: ChatRules.pushForgetKey(appId)) == old {
                    defaults.removeObject(forKey: ChatRules.pushForgetKey(appId))
                }
            case .failed:
                pushForgetFailed = true
                return
            case .noAnswer:
                pushTriedAt = Date()
                return
            }
        }
        // After a sign-out: not before the next person has a thread.
        if defaults.bool(forKey: ChatRules.pushHeldKey(appId)) {
            guard storedToken(appId) != nil else { return }
            defaults.removeObject(forKey: ChatRules.pushHeldKey(appId))
        }
        guard let device = ChatRules.pushDevice(
            env: env,
            config: config,
            token: pushToken,
            bundleId: Bundle.main.bundleIdentifier,
            environment: Self.pushEnvironment,
            language: Locale.preferredLanguages.first ?? "en"
        ), ChatRules.pushRegistrationDue(answered: pushAnswered, next: device), pushMayTry()
        else { return }
        let signOuts = ChatSignOuts.current
        let answer = await sendPush("POST", ChatRules.pushDeviceBody(device, visitorId: env.visitorId), env)
        // A sign-out while this was on its way: forget() has the server
        // forget the phone next, so nothing is kept here.
        guard ChatSignOuts.current == signOuts else { return }
        switch answer {
        case .ok:
            pushAnswered = device
            pushTriedAt = nil
            if let data = try? JSONEncoder().encode(device) { defaults.set(data, forKey: ChatRules.pushKey(appId)) }
            log("push token registered (\(device.environment))")
        case .notTaken:
            // No such app, or its chat is off: this phone is not registered.
            pushAnswered = device
            defaults.removeObject(forKey: ChatRules.pushKey(appId))
            log("the server did not take the push token")
        case .failed:
            pushAnswered = device
            log("push token not registered (the server); the next launch tries again")
        case .noAnswer:
            pushTriedAt = Date()
            log("push token not registered (network)")
        }
    }

    /// Whether enough time has passed since a request got no answer.
    private func pushMayTry() -> Bool {
        guard let at = pushTriedAt else { return true }
        let waited = Date().timeIntervalSince(at)
        return waited < 0 || waited >= ChatRules.pushRetryAfter
    }

    /// POST or DELETE /api/live-chat/push-devices (ChatRules.pushAnswer).
    /// No Authorization header: the phone is named by the app and its token.
    private func sendPush(_ method: String, _ body: [String: Any], _ env: ChatRules.Env) async -> ChatRules.PushAnswer {
        guard let url = ChatRules.pushDevicesURL(apiUrl: env.apiUrl),
              let json = try? JSONSerialization.data(withJSONObject: body)
        else { return .failed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .noAnswer }
        return ChatRules.pushAnswer(status: (response as? HTTPURLResponse)?.statusCode, body: data)
    }

    // MARK: Where to draw

    /// The app's own window in the scene on screen.
    static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        guard let scene else { return nil }
        return scene.keyWindow ?? scene.windows.first { $0.windowLevel == .normal && !$0.isHidden }
    }

    /// The screen on top, which presents the chat.
    static func topController(_ root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

// MARK: - The bubble

/// The floating chat bubble, on the app's pages: LiveChat.keepOnPages puts it
/// just above the window's root view, so anything the app presents over its
/// pages (a sheet, a full-screen cover, an alert) covers it (4.15.2). It
/// starts in the owner's corner; press, hold and move to drag it, and it stays
/// where it was left from then on.
final class ChatBubbleView: UIView {
    static let margin: CGFloat = 20

    /// The circle, in points.
    let size: CGFloat
    /// The owner's "Glass" style: Liquid Glass on iOS 26 and later, frosted glass before.
    let glass: Bool
    /// The owner's circle and icon colors (#rrggbb), as the config gave them.
    let colors: (String, String)
    private let tint: UIColor
    private let ink: UIColor
    /// The owner's corner: bottom-right, bottom-left, top-right or top-left.
    var position = "bottom-right"
    /// Points the app keeps free above the bottom safe area: the bubble starts
    /// above them and is never dragged into them.
    var bottomPadding: CGFloat = 0

    private let appId: String
    private let onTap: () -> Void
    /// The bubble's spoken words, in the phone's first language.
    private let words = ChatRules.ChatWords.forLanguage(Locale.preferredLanguages.first ?? "en")
    private let pill = UILabel()
    private let dot = UIView()
    /// The red number and the green dot, scaled with the circle.
    private let badge: ChatRules.BadgeMetrics
    /// Distance from the window's right and bottom edges, safe area included,
    /// the way the React Native bubble keeps it. Set once the person drags it
    /// (now or on an earlier launch); until then the bubble follows the corner.
    private var dragged: CGPoint?
    private var dragStart: CGPoint = .zero
    /// True while the person drags the bubble: it does not wiggle then.
    private(set) var isDragging = false
    static let wiggleKey = "affiliateo-wiggle"

    init(
        appId: String,
        size: CGFloat,
        glass: Bool = false,
        color: String = "#1754d8",
        iconColor: String = "#ffffff",
        onTap: @escaping () -> Void
    ) {
        self.appId = appId
        self.size = size
        self.glass = glass
        self.colors = (color, iconColor)
        self.tint = Self.uiColor(color) ?? Self.brand
        self.ink = Self.uiColor(iconColor) ?? .white
        self.onTap = onTap
        self.badge = ChatRules.badgeMetrics(size: Double(size))
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        layer.cornerRadius = size / 2
        if glass {
            addGlass()
        } else {
            addSolid()
        }

        pill.backgroundColor = UIColor(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
        pill.textColor = .white
        pill.font = .systemFont(ofSize: CGFloat(badge.pillFont), weight: .bold)
        pill.textAlignment = .center
        pill.layer.cornerRadius = CGFloat(badge.pillHeight) / 2
        pill.layer.borderWidth = CGFloat(badge.border)
        pill.layer.borderColor = UIColor.white.cgColor
        pill.clipsToBounds = true
        pill.isHidden = true
        addSubview(pill)

        let dotSize = CGFloat(badge.dot)
        dot.frame = CGRect(x: -CGFloat(badge.dotOffset), y: -CGFloat(badge.dotOffset), width: dotSize, height: dotSize)
        dot.backgroundColor = UIColor(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255, alpha: 1)
        dot.layer.cornerRadius = dotSize / 2
        dot.layer.borderWidth = CGFloat(badge.border)
        dot.layer.borderColor = UIColor.white.cgColor
        dot.isHidden = true
        addSubview(dot)

        dragged = savedOffset()

        isAccessibilityElement = true
        // In the person's language (4.15.2, review E14); update(unread:online:) adds the count.
        accessibilityLabel = words.chat
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let brand = UIColor(red: 0x17 / 255, green: 0x54 / 255, blue: 0xD8 / 255, alpha: 1)

    static func uiColor(_ hex: String) -> UIColor? {
        guard let c = ChatRules.rgb(hex) else { return nil }
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// The solid circle, as on the website: the owner's color, a little lighter
    /// at the top left, with the speech bubble in the icon color.
    private func addSolid() {
        layer.shadowColor = tint.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        let circle = CAGradientLayer()
        circle.frame = bounds
        circle.cornerRadius = size / 2
        circle.startPoint = CGPoint(x: 0, y: 0)
        circle.endPoint = CGPoint(x: 1, y: 1)
        // color-mix(in oklab, color 55%, white), close enough in plain RGB.
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        let light = UIColor(red: r * 0.55 + 0.45, green: g * 0.55 + 0.45, blue: b * 0.55 + 0.45, alpha: 1)
        circle.colors = [light.cgColor, tint.cgColor]
        layer.addSublayer(circle)
        let glyph = CAShapeLayer()
        glyph.path = Self.speechBubble(in: size).cgPath
        glyph.fillColor = ink.cgColor
        layer.addSublayer(glyph)
    }

    /// The "Glass" style: the screen shows through a blue-tinted glass circle
    /// (Liquid Glass on iOS 26 and later, which also answers a press; frosted
    /// glass before), with the white speech bubble on top.
    private func addGlass() {
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        let effect: UIVisualEffectView
        // Liquid Glass needs the iOS 26 SDK (Xcode 26, Swift 6.2): an app built
        // with an older Xcode still compiles and gets the frosted glass
        // (4.15.2, review E19).
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let liquid = UIGlassEffect()
            liquid.tintColor = tint.withAlphaComponent(0.6)
            liquid.isInteractive = true
            effect = UIVisualEffectView(effect: liquid)
            effect.cornerConfiguration = .capsule()
        } else {
            effect = frostedGlass()
        }
        #else
        effect = frostedGlass()
        #endif
        effect.frame = bounds
        addSubview(effect)

        let glyph = CAShapeLayer()
        glyph.path = Self.speechBubble(in: size).cgPath
        glyph.fillColor = ink.cgColor
        effect.contentView.layer.addSublayer(glyph)
    }

    /// Frosted glass, tinted with the circle's color, with a fine white edge:
    /// the glass before iOS 26, and on any iOS for an app built with an older Xcode.
    private func frostedGlass() -> UIVisualEffectView {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        let wash = UIView(frame: bounds)
        wash.backgroundColor = tint.withAlphaComponent(0.6)
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effect.contentView.addSubview(wash)
        effect.layer.cornerRadius = size / 2
        effect.layer.borderWidth = 1
        effect.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        effect.clipsToBounds = true
        return effect
    }

    /// The website bubble's speech bubble (public/chat.js, a 24-point drawing)
    /// filling 60% of the circle.
    static func speechBubble(in size: CGFloat) -> UIBezierPath {
        let scale = size * 0.6 / 24
        let inset = size * 0.2
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: inset + x * scale, y: inset + y * scale) }
        let path = UIBezierPath()
        path.move(to: p(12, 2.5))
        path.addCurve(to: p(21.5, 11.25), controlPoint1: p(17.25, 2.5), controlPoint2: p(21.5, 6.4))
        path.addCurve(to: p(12, 20), controlPoint1: p(21.5, 16.1), controlPoint2: p(17.25, 20))
        path.addCurve(to: p(8.87, 19.52), controlPoint1: p(10.9, 20), controlPoint2: p(9.85, 19.83))
        path.addCurve(to: p(3.05, 21.45), controlPoint1: p(7.3, 20.9), controlPoint2: p(5.2, 21.55))
        path.addCurve(to: p(5.45, 17.85), controlPoint1: p(4.35, 20.55), controlPoint2: p(5.2, 19.3))
        path.addCurve(to: p(2.5, 11.25), controlPoint1: p(3.6, 16.25), controlPoint2: p(2.5, 13.87))
        path.addCurve(to: p(12, 2.5), controlPoint1: p(2.5, 6.4), controlPoint2: p(6.75, 2.5))
        path.close()
        return path
    }

    func update(unread: Int, online: Bool) {
        if let text = ChatRules.badgeText(unread) {
            pill.text = text
            let height = CGFloat(badge.pillHeight)
            let offset = CGFloat(badge.pillOffset)
            let width = max(height, ceil(pill.intrinsicContentSize.width) + 2 * CGFloat(badge.pillPadding))
            pill.frame = CGRect(x: size + offset - width, y: -offset, width: width, height: height)
            pill.isHidden = false
            dot.isHidden = true
            accessibilityLabel = words.unread(unread)
        } else {
            pill.isHidden = true
            dot.isHidden = !online
            accessibilityLabel = words.chat
        }
        accessibilityValue = nil
    }

    /// In the owner's corner, or where the person left it, kept inside the window.
    func place() {
        guard let window = superview else { return }
        if let dragged {
            autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
            move(to: dragged)
            return
        }
        let insets = window.safeAreaInsets
        let corner = ChatRules.cornerOffset(
            position: position,
            size: Double(size),
            width: Double(window.bounds.width),
            height: Double(window.bounds.height),
            insets: (Double(insets.top), Double(insets.bottom + bottomPadding), Double(insets.left), Double(insets.right)),
            margin: Double(Self.margin)
        )
        // Keeps the corner when the window turns or resizes.
        var mask: UIView.AutoresizingMask = []
        mask.insert(position.hasPrefix("top") ? .flexibleBottomMargin : .flexibleTopMargin)
        mask.insert(position.hasSuffix("left") ? .flexibleRightMargin : .flexibleLeftMargin)
        autoresizingMask = mask
        move(to: CGPoint(x: corner.x, y: corner.y))
    }

    /// Where the bubble is now, as distance from the right and bottom edges.
    private var currentOffset: CGPoint {
        guard let window = superview else { return .zero }
        return CGPoint(x: window.bounds.width - frame.maxX, y: window.bounds.height - frame.maxY)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        guard let window = superview else { return point }
        let insets = window.safeAreaInsets
        let bounds = window.bounds
        return CGPoint(
            x: max(insets.right + 8, min(bounds.width - size - insets.left - 8, point.x)),
            y: CGFloat(ChatRules.clampedBottom(
                Double(point.y),
                size: Double(size),
                height: Double(bounds.height),
                insets: (Double(insets.top), Double(insets.bottom)),
                padding: Double(bottomPadding)
            ))
        )
    }

    private func move(to point: CGPoint) {
        guard let window = superview else { return }
        let next = clamp(point)
        frame = CGRect(
            x: window.bounds.width - next.x - size,
            y: window.bounds.height - next.y - size,
            width: size,
            height: size
        )
    }

    /// One wiggle (4.17.0): the whole bubble turns left and right around its
    /// center, three swings that die down, and grows a touch on the way
    /// (ChatRules.wiggleAngle and wiggleScale), 0.9 s, then it rests. It is
    /// played on the bubble's own layer, so the circle, the icon, the red
    /// number and the green dot move as one piece. The curve is sampled once
    /// per frame with straight steps between the samples and no easing, so
    /// it never stops and starts on the way.
    func wiggle() {
        guard !isDragging, layer.animation(forKey: Self.wiggleKey) == nil else { return }
        let curve = ChatRules.wiggleCurve()
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = curve.angles.map { $0 * Double.pi / 180 }
        turn.calculationMode = .linear
        let size = CAKeyframeAnimation(keyPath: "transform.scale")
        size.values = curve.scales
        size.calculationMode = .linear
        turn.duration = ChatRules.wiggleDuration
        size.duration = ChatRules.wiggleDuration
        let both = CAAnimationGroup()
        both.animations = [turn, size]
        both.duration = ChatRules.wiggleDuration
        both.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(both, forKey: Self.wiggleKey)
    }

    /// Cuts a wiggle that is playing: the bubble is back at rest at once
    /// (no turn, its own size). For a drag, and when the bubble is hidden or
    /// the chat opens.
    func stopWiggle() {
        layer.removeAnimation(forKey: Self.wiggleKey)
    }

    @objc private func tapped() {
        onTap()
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // A wiggle stops under the finger and none starts during the drag.
            isDragging = true
            stopWiggle()
            dragStart = currentOffset
            autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        case .changed:
            let moved = gesture.translation(in: superview)
            let next = clamp(CGPoint(x: dragStart.x - moved.x, y: dragStart.y - moved.y))
            dragged = next
            move(to: next)
        case .ended, .cancelled:
            isDragging = false
            saveOffset()
        case .failed:
            isDragging = false
        default:
            break
        }
    }

    // The same JSON the React Native bubble keeps: {"x":..,"y":..}.
    private func savedOffset() -> CGPoint? {
        guard let raw = UserDefaults.standard.string(forKey: ChatRules.positionKey(appId)),
              let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let x = json["x"] as? Double, let y = json["y"] as? Double
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func saveOffset() {
        guard let dragged,
              let data = try? JSONSerialization.data(withJSONObject: ["x": Double(dragged.x), "y": Double(dragged.y)]),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(raw, forKey: ChatRules.positionKey(appId))
    }
}

// MARK: - The chat screen

/// Affiliateo's hosted chat page, in a sheet that slides up over the app
/// (4.15.0; LiveChat.presentChat sets it up). Its own header has the close
/// button; links the business sends open in the browser when the person taps
/// them. Only this app's own chat page loads in it (4.15.4, review S18).
final class ChatViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static let bridgeName = "affiliateoChat"

    var onToken: ((String) -> Void)?
    var onRead: (() -> Void)?
    var onClosed: (() -> Void)?

    private var url: URL
    private let apiUrl: String
    /// The app this sheet was opened for: only its chat page loads and speaks.
    private let appId: String
    private let dark: Bool
    private let inspectable: Bool
    private var webView: WKWebView?
    private var finished = false

    init(url: URL, apiUrl: String, appId: String, dark: Bool, inspectable: Bool) {
        self.url = url
        self.apiUrl = apiUrl
        self.appId = appId
        self.dark = dark
        self.inspectable = inspectable
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        overrideUserInterfaceStyle = dark ? .dark : .light
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredStatusBarStyle: UIStatusBarStyle { dark ? .lightContent : .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        let background = dark ? UIColor(red: 0x11 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1) : .white
        view.backgroundColor = background

        let configuration = WKWebViewConfiguration()
        // A private store for this screen only (4.15.1): the page's own copy of
        // the key and its message cache never reach the disk, so nothing is
        // left after a sign-out. The key lives in the Keychain and goes with
        // logout(); the page loads from the server each time.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakScriptHandler(self), name: Self.bridgeName)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { web.isInspectable = inspectable }
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // The page sits above the keyboard, so its message box stays in sight.
            web.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        webView = web
        web.load(URLRequest(url: url))
        url = ChatRules.withoutFresh(url)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    fileprivate func received(_ message: WKScriptMessage) {
        // Only this app's own chat page may speak: never a frame inside it,
        // and never another app's chat page (4.15.4, review S18), whose key
        // would replace this person's.
        guard message.frameInfo.isMainFrame,
              let host = URL(string: apiUrl)?.host,
              message.frameInfo.securityOrigin.host == host,
              let page = message.frameInfo.request.url,
              ChatRules.isChatPage(page, apiUrl: apiUrl, appId: appId)
        else { return }
        switch ChatRules.parseHostMessage(message.body) {
        case .token(let token): onToken?(token)
        case .read: onRead?()
        case .close: dismiss(animated: true)
        default: break
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        onClosed?()
    }

    // MARK: Navigation

    /// ChatRules.navigation decides (4.15.4, review S18): this app's own chat
    /// page loads, frames stay on the chat's origin, and a link leaves the
    /// sheet only when the person taps it, never for a script or a redirect.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let frame: ChatRules.Frame
        if let targetFrame = navigationAction.targetFrame {
            frame = targetFrame.isMainFrame ? .main : .sub
        } else {
            frame = .newWindow
        }
        switch decide(target, frame: frame, navigationAction) {
        case .load:
            decisionHandler(.allow)
        case .openOutside:
            decisionHandler(.cancel)
            openOutside(target)
        case .block:
            decisionHandler(.cancel)
        }
    }

    /// A link that asks for a new window (target="_blank", window.open): it
    /// opens in the browser when the person tapped it, and never in the sheet.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let target = navigationAction.request.url, decide(target, frame: .newWindow, navigationAction) == .openOutside {
            openOutside(target)
        }
        return nil
    }

    private func decide(_ target: URL, frame: ChatRules.Frame, _ action: WKNavigationAction) -> ChatRules.Navigation {
        ChatRules.navigation(
            to: target,
            frame: frame,
            tapped: action.navigationType == .linkActivated,
            apiUrl: apiUrl,
            appId: appId
        )
    }

    /// iOS ended the page's process (memory pressure): load it again, without
    /// `fresh=1`. The page keeps the thread's token in its own storage too.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }

    private func openOutside(_ target: URL) {
        guard ChatRules.opensOutside(target) else { return }
        UIApplication.shared.open(target)
    }
}

/// WKUserContentController keeps its handlers alive; this one does not keep
/// the screen alive with it.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ChatViewController?

    init(_ target: ChatViewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.received(message)
    }
}
#endif
