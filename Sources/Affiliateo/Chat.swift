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
    private var wantsBubble = false
    private var wantsOpen = false
    private var observing = false
    private var bubble: ChatBubbleView?
    private weak var screen: ChatViewController?

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
    }

    /// The owner may have switched the chat on or off while the app was away,
    /// and a reply may have come in.
    private func cameToFront() {
        guard wantsBubble, env != nil else { return }
        Task {
            await refreshConfig(force: false)
            placeBubble()
            await refreshUnread(force: false)
        }
    }

    private func setUnread(_ count: Int) {
        unread = count
        bubble?.update(unread: unread, online: config?.online ?? false)
    }

    // MARK: The bubble

    private func placeBubble() {
        guard wantsBubble, let env, let config, config.enabled, config.showBubble else {
            removeBubble()
            return
        }
        guard screen == nil else {
            bubble?.isHidden = true
            return
        }
        // No window yet (the app is still launching): the next foreground places it.
        guard let window = Self.hostWindow() else { return }
        let view = bubble ?? ChatBubbleView(appId: env.appId) { LiveChat.shared.open() }
        bubble = view
        if view.superview !== window {
            view.removeFromSuperview()
            window.addSubview(view)
        }
        view.place()
        window.bringSubviewToFront(view)
        view.isHidden = false
        view.update(unread: unread, online: config.online)
    }

    private func removeBubble() {
        bubble?.removeFromSuperview()
        bubble = nil
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
/// screen the app presents later (a sheet, a paywall) covers it. Press, hold
/// and move to drag it; it remembers where it was left.
final class ChatBubbleView: UIView {
    static let size: CGFloat = 56
    static let margin: CGFloat = 20

    private let appId: String
    private let onTap: () -> Void
    private let art = UIImageView()
    private let pill = UILabel()
    private let dot = UIView()
    /// Distance from the window's right and bottom edges, safe area included,
    /// the way the React Native bubble keeps it. Nil until placed.
    private var offset: CGPoint?
    private var dragStart: CGPoint = .zero

    init(appId: String, onTap: @escaping () -> Void) {
        self.appId = appId
        self.onTap = onTap
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        // Keeps the distance from the right and bottom edges when the window
        // turns or resizes.
        autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]

        layer.cornerRadius = Self.size / 2
        backgroundColor = UIColor(red: 0x17 / 255, green: 0x54 / 255, blue: 0xD8 / 255, alpha: 1)
        layer.shadowColor = backgroundColor?.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)

        art.frame = bounds
        art.layer.cornerRadius = Self.size / 2
        art.clipsToBounds = true
        if let data = ChatBubbleImage.pngData { art.image = UIImage(data: data, scale: 3) }
        addSubview(art)

        pill.backgroundColor = UIColor(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
        pill.textColor = .white
        pill.font = .systemFont(ofSize: 11, weight: .bold)
        pill.textAlignment = .center
        pill.layer.cornerRadius = 10
        pill.layer.borderWidth = 2
        pill.layer.borderColor = UIColor.white.cgColor
        pill.clipsToBounds = true
        pill.isHidden = true
        addSubview(pill)

        dot.frame = CGRect(x: -2, y: -2, width: 16, height: 16)
        dot.backgroundColor = UIColor(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255, alpha: 1)
        dot.layer.cornerRadius = 8
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.isHidden = true
        addSubview(dot)

        isAccessibilityElement = true
        accessibilityLabel = "Chat"
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(unread: Int, online: Bool) {
        if let text = ChatRules.badgeText(unread) {
            pill.text = text
            let width = max(20, ceil(pill.intrinsicContentSize.width) + 10)
            pill.frame = CGRect(x: Self.size + 4 - width, y: -4, width: width, height: 20)
            pill.isHidden = false
            dot.isHidden = true
            accessibilityValue = text
        } else {
            pill.isHidden = true
            dot.isHidden = !online
            accessibilityValue = nil
        }
    }

    /// Where it was left last time, kept inside the window.
    func place() {
        guard let window = superview else { return }
        let insets = window.safeAreaInsets
        let start = offset ?? savedOffset() ?? CGPoint(x: Self.margin + insets.right, y: Self.margin + insets.bottom)
        move(to: start)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        guard let window = superview else { return point }
        let insets = window.safeAreaInsets
        let bounds = window.bounds
        return CGPoint(
            x: max(insets.right + 8, min(bounds.width - Self.size - insets.left - 8, point.x)),
            y: max(insets.bottom + 8, min(bounds.height - Self.size - insets.top - 8, point.y))
        )
    }

    private func move(to point: CGPoint) {
        guard let window = superview else { return }
        let next = clamp(point)
        offset = next
        frame = CGRect(
            x: window.bounds.width - next.x - Self.size,
            y: window.bounds.height - next.y - Self.size,
            width: Self.size,
            height: Self.size
        )
    }

    @objc private func tapped() {
        onTap()
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragStart = offset ?? .zero
        case .changed:
            let moved = gesture.translation(in: superview)
            move(to: CGPoint(x: dragStart.x - moved.x, y: dragStart.y - moved.y))
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
        guard let offset,
              let data = try? JSONSerialization.data(withJSONObject: ["x": Double(offset.x), "y": Double(offset.y)]),
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
