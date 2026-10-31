#if os(iOS)
import UIKit
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
    private weak var screen: ChatViewController?
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
        bottomPadding = max(0, min(points, 400))
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
        return answer
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
                if event == "message", (frame["message"] as? [String: Any])?["sender"] as? String == "team" {
                    setUnread(unread + 1)
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
        guard screen == nil else { return }
        guard let env, let window = Self.hostWindow(), let presenter = Self.topController(window.rootViewController) else {
            log("openChat: no screen to show the chat on yet")
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
        }
        controller.onRead = { LiveChat.shared.setUnread(0) }
        controller.onClosed = { LiveChat.shared.chatClosed() }
        screen = controller
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
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak controller] in
            guard let self, let controller, self.screen === controller, controller.presentingViewController == nil else { return }
            self.log("openChat: the screen on top was busy presenting; try again")
            self.screen = nil
            self.placeBubble()
        }
    }

    private func chatClosed() {
        screen = nil
        setUnread(0)
        placeBubble()
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
            y: max(insets.bottom + bottomPadding + 8, min(bounds.height - size - insets.top - 8, point.y))
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

    @objc private func tapped() {
        onTap()
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragStart = currentOffset
            autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        case .changed:
            let moved = gesture.translation(in: superview)
            let next = clamp(CGPoint(x: dragStart.x - moved.x, y: dragStart.y - moved.y))
            dragged = next
            move(to: next)
        case .ended, .cancelled:
            saveOffset()
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
