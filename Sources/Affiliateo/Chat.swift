#if os(iOS)
import UIKit
import WebKit

/// Live Chat (4.14.0): the app's users chat in real time with the business,
/// which answers from the Live Chat inbox in its Affiliateo dashboard.
///
///     Affiliateo.showChatBubble()   the bubble on every screen
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
/// number live.
///
/// The visitor's key to their thread (a token the server hands out with their
/// first message) is kept in UserDefaults, the React Native SDK's choice too:
/// a reinstall clears it and starts a new thread, which is what the server
/// expects. The Keychain would carry it past a reinstall.
@MainActor
final class LiveChat {
    static let shared = LiveChat()

    private var config: ChatRules.Config?
    private var configCheckedAt: Date?
    private var configTask: Task<ChatRules.Config, Never>?
    private var unreadCheckedAt: Date?
    private var unread = 0
    /// The greeting nobody on this phone has seen yet: one unread message.
    private var greetingPending = false
    /// The name the app last passed to page(_:).
    private var currentScreen: String?
    private var wantsBubble = false
    private var wantsOpen = false
    private var observing = false
    private var inFront = true
    private var bubble: ChatBubbleView?
    private weak var screen: ChatViewController?

    // The live socket on the thread, for the red number.
    private var socket: URLSessionWebSocketTask?
    private var socketTries = 0
    private var socketRetry: Task<Void, Never>?
    private var socketPing: Timer?

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
        guard env != nil else { return }
        Task {
            await refreshConfig(force: config == nil)
            placeBubble()
            await refreshUnread(force: true)
        }
    }

    func hideBubble() {
        wantsBubble = false
        removeBubble()
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
                return (response as? HTTPURLResponse)?.statusCode == 200 ? ChatRules.parseConfig(data) : .off
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
        // Somebody who already wrote has seen the greeting.
        if answer.enabled, let id = answer.bubble.greetingId, storedToken(env.appId) == nil {
            greetingPending = UserDefaults.standard.string(forKey: ChatRules.greetingKey(env.appId)) != id
        } else {
            greetingPending = false
        }
        return answer
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
              let count = ChatRules.parseUnread(data)
        else { return }
        // An open chat has just shown them everything.
        if screen == nil { setUnread(count) }
    }

    private func storedToken(_ appId: String) -> String? {
        let token = UserDefaults.standard.string(forKey: ChatRules.tokenKey(appId))
        return ChatRules.isToken(token) ? token : nil
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
    }

    private func setUnread(_ count: Int) {
        unread = count
        paintBubble()
    }

    private func paintBubble() {
        bubble?.update(unread: unread + (greetingPending ? 1 : 0), online: config?.online ?? false)
    }

    // MARK: The bubble

    private func placeBubble() {
        guard wantsBubble, let env, let config, config.enabled, config.showBubble else {
            removeBubble()
            return
        }
        let style = config.bubble
        guard screen == nil, ChatRules.bubbleShowsOn(mode: style.pageMode, rules: style.pageRules, place: currentScreen) else {
            bubble?.isHidden = true
            stopSocket()
            return
        }
        // No window yet (the app is still launching): the next foreground places it.
        guard let window = Self.hostWindow() else { return }
        // An iPhone gets the owner's phone size ("auto" makes it smaller), an iPad the other.
        let size = CGFloat(UIDevice.current.userInterfaceIdiom == .phone ? style.sizePhone : style.size)
        if let existing = bubble, existing.size != size {
            existing.removeFromSuperview()
            bubble = nil
        }
        let view = bubble ?? ChatBubbleView(appId: env.appId, size: size) { LiveChat.shared.open() }
        bubble = view
        view.position = style.position
        if view.superview !== window {
            view.removeFromSuperview()
            window.addSubview(view)
        }
        view.place()
        window.bringSubviewToFront(view)
        view.isHidden = false
        paintBubble()
        startSocket()
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
                  + "/api/live-chat/stream?token=\(ChatRules.encode(token))")
        else { return }
        let task = URLSession.shared.webSocketTask(with: url)
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
            theme: dark ? "dark" : "light"
        ) else { return }
        let appId = env.appId
        let controller = ChatViewController(url: url, apiUrl: env.apiUrl, dark: dark, inspectable: env.debug)
        controller.onToken = { token in
            UserDefaults.standard.set(token, forKey: ChatRules.tokenKey(appId))
        }
        controller.onRead = { LiveChat.shared.setUnread(0) }
        controller.onClosed = { LiveChat.shared.chatClosed() }
        screen = controller
        // They see the greeting now; a new one counts again.
        if let id = config?.bubble.greetingId { UserDefaults.standard.set(id, forKey: ChatRules.greetingKey(appId)) }
        greetingPending = false
        stopSocket()
        bubble?.isHidden = true
        presenter.present(controller, animated: true)
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

/// The floating chat bubble: the app's window gets it as its top view, so a
/// screen the app presents later (a sheet, a paywall) covers it. It starts in
/// the owner's corner; press, hold and move to drag it, and it stays where it
/// was left from then on.
final class ChatBubbleView: UIView {
    static let margin: CGFloat = 20

    /// The circle, in points.
    let size: CGFloat
    /// The owner's corner: bottom-right, bottom-left, top-right or top-left.
    var position = "bottom-right"

    private let appId: String
    private let onTap: () -> Void
    private let art = UIImageView()
    private let pill = UILabel()
    private let dot = UIView()
    /// The red number and the green dot, scaled with the circle.
    private let badge: ChatRules.BadgeMetrics
    /// Distance from the window's right and bottom edges, safe area included,
    /// the way the React Native bubble keeps it. Set once the person drags it
    /// (now or on an earlier launch); until then the bubble follows the corner.
    private var dragged: CGPoint?
    private var dragStart: CGPoint = .zero

    init(appId: String, size: CGFloat, onTap: @escaping () -> Void) {
        self.appId = appId
        self.size = size
        self.onTap = onTap
        self.badge = ChatRules.badgeMetrics(size: Double(size))
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        layer.cornerRadius = size / 2
        backgroundColor = UIColor(red: 0x17 / 255, green: 0x54 / 255, blue: 0xD8 / 255, alpha: 1)
        layer.shadowColor = backgroundColor?.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)

        art.frame = bounds
        art.layer.cornerRadius = size / 2
        art.clipsToBounds = true
        if let data = ChatBubbleImage.pngData { art.image = UIImage(data: data, scale: 3) }
        addSubview(art)

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
        accessibilityLabel = "Chat"
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(unread: Int, online: Bool) {
        if let text = ChatRules.badgeText(unread) {
            pill.text = text
            let height = CGFloat(badge.pillHeight)
            let offset = CGFloat(badge.pillOffset)
            let width = max(height, ceil(pill.intrinsicContentSize.width) + 2 * CGFloat(badge.pillPadding))
            pill.frame = CGRect(x: size + offset - width, y: -offset, width: width, height: height)
            pill.isHidden = false
            dot.isHidden = true
            accessibilityValue = text
        } else {
            pill.isHidden = true
            dot.isHidden = !online
            accessibilityValue = nil
        }
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
            insets: (Double(insets.top), Double(insets.bottom), Double(insets.left), Double(insets.right)),
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
            y: max(insets.bottom + 8, min(bounds.height - size - insets.top - 8, point.y))
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

/// Affiliateo's hosted chat page, full screen. Its own header has the close
/// button; links the business sends open in the browser.
final class ChatViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static let bridgeName = "affiliateoChat"

    var onToken: ((String) -> Void)?
    var onRead: (() -> Void)?
    var onClosed: (() -> Void)?

    private let url: URL
    private let apiUrl: String
    private let dark: Bool
    private let inspectable: Bool
    private var webView: WKWebView?
    private var finished = false

    init(url: URL, apiUrl: String, dark: Bool, inspectable: Bool) {
        self.url = url
        self.apiUrl = apiUrl
        self.dark = dark
        self.inspectable = inspectable
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finish() }
    }

    fileprivate func received(_ message: WKScriptMessage) {
        // Only the chat page itself may speak: never a frame inside it.
        guard message.frameInfo.isMainFrame,
              let host = URL(string: apiUrl)?.host,
              message.frameInfo.securityOrigin.host == host
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false || ChatRules.isChatPage(target, apiUrl: apiUrl) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openOutside(target)
    }

    /// A link that asks for a new window (target="_blank").
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let target = navigationAction.request.url { openOutside(target) }
        return nil
    }

    /// iOS ended the page's process (memory pressure): load it again. The
    /// page keeps the thread's token in its own storage too.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }

    private func openOutside(_ target: URL) {
        guard let scheme = target.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return }
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
