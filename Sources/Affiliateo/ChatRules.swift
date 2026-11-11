import Foundation

/// The parts of Live Chat (4.14.0) that need no screen, kept apart so they
/// can be unit tested on any platform. The screens are in Chat.swift.
///
/// The chat SCREEN is Affiliateo's hosted page (/embed/chat/{app}) in a web
/// view, the same page the website bubble and the React Native, Kotlin and
/// Flutter SDKs open, so it looks and behaves the same everywhere. Everything
/// about the person rides in the URL fragment, which never reaches a server
/// log.
enum ChatRules {
    /// How long a config answer counts before the next foreground asks again.
    static let configMaxAge: TimeInterval = 60
    /// How long an unread count counts before the next foreground asks again.
    static let unreadMaxAge: TimeInterval = 30

    /// What Live Chat needs to know about this install. The ids are labels
    /// for the business's inbox, never credentials.
    struct Env {
        let appId: String
        let apiUrl: String
        let deviceId: String?
        let visitorId: String?
        let userId: String?
        let optedOut: Bool
        let debug: Bool
    }

    /// What `/api/live-chat/config` answered.
    struct Config: Equatable {
        /// The business has the chat on for this app.
        let enabled: Bool
        /// The bubble should show (on, and not hidden by "only while someone
        /// is online").
        let showBubble: Bool
        /// Someone on the business's team is online right now.
        let online: Bool
        /// The owner's corner, size and screens for the bubble.
        var bubble: Bubble = .standard
        /// The Live Chat app's name (`app.name`): the title of its
        /// notifications (4.17.0).
        var appName: String? = nil
        /// The owner's greeting, as the chat window shows it first (4.17.0).
        var greeting: String? = nil
        /// The greeting in other languages, by two-letter language, when the
        /// server sends them (`greetings`).
        var greetings: [String: String] = [:]

        static let off = Config(enabled: false, showBubble: false, online: false)
    }

    /// The owner's say over the bubble (the website's
    /// lib/live-chat/bubble-options.ts; KEEP IN STEP).
    struct Bubble: Equatable {
        /// bottom-right, bottom-left, top-right or top-left.
        var position = "bottom-right"
        /// The circle on an iPad, in points: 48, 56 or 64.
        var size: Double = 56
        /// The circle on an iPhone (smaller than `size` for the owner's "auto").
        var sizePhone: Double = 56
        /// all, only or except.
        var pageMode = "all"
        /// Screen names, `*` matching anything.
        var pageRules: [String] = []
        /// Set when the greeting counts as one unread message until the chat
        /// is first opened; a new greeting has a new id.
        var greetingId: String?
        /// "standard" (a solid circle) or "glass" (Liquid Glass on iOS 26
        /// and later, frosted glass before), tinted with `color`.
        var style = "standard"
        /// The owner's circle color and the speech bubble's inside it, #rrggbb.
        var color = "#1754d8"
        var iconColor = "#ffffff"
        /// Seconds between two wiggles of the bubble (4.17.0); 0 is off, and
        /// so is a server from before the wiggle.
        var wiggleSeconds = 0

        static let standard = Bubble()
    }

    /// What the chat page tells the app (window.webkit.messageHandlers.affiliateoChat).
    enum HostMessage: Equatable {
        case ready
        /// The server opened a thread and handed out its token: keep it.
        case token(String)
        /// The person saw every reply.
        case read
        /// The page's close button.
        case close
        case message
    }

    // MARK: Whose thread it is (4.15.1)

    /// Whether a sign-in switches this phone from one signed-in person to a
    /// DIFFERENT one. Then the last person's chat thread is forgotten first,
    /// as `logout()` does; signing in from anonymous (nobody before) keeps
    /// the person's own thread.
    static func switchesPerson(previous: String?, next: String) -> Bool {
        guard let previous, !previous.isEmpty else { return false }
        return previous != next
    }

    // MARK: Storage, the same key names as the React Native SDK

    /// Where versions before 4.15.4 kept the thread key in UserDefaults;
    /// ChatTokenStore moves a key found there to the Keychain.
    static func tokenKey(_ appId: String) -> String { "affiliateo_chat_token_\(appId)" }
    static func positionKey(_ appId: String) -> String { "affiliateo_chat_pos_\(appId)" }
    static func greetingKey(_ appId: String) -> String { "affiliateo_chat_greeting_seen_\(appId)" }
    /// The server's last answer about the chat (4.15.0): the bubble shows from
    /// it at once on the next launch while a fresh one is asked for.
    static func configKey(_ appId: String) -> String { "affiliateo_chat_config_\(appId)" }
    /// The greeting this install already sent as a notification (4.17.0):
    /// its id, so the same greeting never goes out twice.
    static func greetingNotifiedKey(_ appId: String) -> String { "affiliateo_chat_greeting_notified_\(appId)" }
    /// What the server last confirmed about this phone's push token (4.17.0).
    static func pushKey(_ appId: String) -> String { "affiliateo_chat_push_\(appId)" }
    /// A push token the server has yet to forget (a sign-out or an opt-out
    /// that could not reach it).
    static func pushForgetKey(_ appId: String) -> String { "affiliateo_chat_push_forget_\(appId)" }
    /// Set by a sign-out: the phone is not registered again until the next
    /// person starts a thread of their own.
    static func pushHeldKey(_ appId: String) -> String { "affiliateo_chat_push_held_\(appId)" }

    // MARK: The token

    private static let tokenRegex = try! NSRegularExpression(pattern: "^lct_[A-Za-z0-9_-]{43}$")

    /// True for a string shaped like a token the server minted.
    static func isToken(_ value: String?) -> Bool {
        guard let value else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return tokenRegex.firstMatch(in: value, range: range) != nil
    }

    // MARK: Server answers

    static func parseConfig(_ data: Data) -> Config {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["enabled"] as? Bool == true
        else { return .off }
        var greetings: [String: String] = [:]
        for (language, text) in json["greetings"] as? [String: Any] ?? [:] {
            if let text = nonEmpty(text) { greetings[String(language.lowercased().prefix(2))] = text }
        }
        return Config(
            enabled: true,
            showBubble: json["show_bubble"] as? Bool == true,
            online: json["online"] as? Bool == true,
            bubble: parseBubble(json["bubble"]),
            appName: nonEmpty((json["app"] as? [String: Any])?["name"]),
            greeting: nonEmpty(json["greeting"]),
            greetings: greetings
        )
    }

    /// Text with something in it, trimmed; nil for anything else.
    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The config's `bubble`, anything missing or odd read as the old fixed bubble.
    static func parseBubble(_ raw: Any?) -> Bubble {
        guard let b = raw as? [String: Any] else { return .standard }
        var bubble = Bubble()
        if let position = b["position"] as? String, ["bottom-left", "top-right", "top-left"].contains(position) {
            bubble.position = position
        }
        if let size = b["size_points"] as? Double, size >= 40, size <= 80 {
            bubble.size = size
            bubble.sizePhone = size
        }
        if let phone = b["size_points_phone"] as? Double, phone >= 40, phone <= 80 { bubble.sizePhone = phone }
        if let mode = b["page_mode"] as? String, mode == "only" || mode == "except" { bubble.pageMode = mode }
        bubble.pageRules = (b["page_rules"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let id = b["greeting_id"] as? String, !id.isEmpty { bubble.greetingId = id }
        if b["style"] as? String == "glass" { bubble.style = "glass" }
        if let color = b["color"] as? String, rgb(color) != nil { bubble.color = color }
        if let color = b["icon_color"] as? String, rgb(color) != nil { bubble.iconColor = color }
        bubble.wiggleSeconds = wiggleSeconds(b["wiggle_seconds"])
        return bubble
    }

    /// What the app's own code asks for (setChatBubbleLook, 4.15.0); each
    /// set field wins over the dashboard's choice, each nil keeps it.
    struct BubbleLook: Equatable {
        var color: String?
        var iconColor: String?
        var style: String?
        var position: String?
        /// One size for phones and tablets alike, in points.
        var size: Double?
        /// The chat's send button and the person's own messages.
        var sendColor: String? = nil
    }

    /// The dashboard's bubble with the app's own choices on top.
    static func applying(_ look: BubbleLook, to bubble: Bubble) -> Bubble {
        var b = bubble
        if let c = look.color { b.color = c }
        if let c = look.iconColor { b.iconColor = c }
        if let s = look.style { b.style = s }
        if let p = look.position { b.position = p }
        if let s = look.size {
            b.size = s
            b.sizePhone = s
        }
        return b
    }

    /// The message box text as the code may pass it: on one line, trimmed,
    /// up to 60 characters; nil when empty.
    static func placeholder(_ text: String?) -> String? {
        let clean = (text ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(60))
    }

    /// A color as the code may write it ("#7C3AED", "7c3aed", "#fa0") as
    /// #rrggbb, lowercase; nil for anything else.
    static func hex(_ value: String) -> String? {
        var v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v.hasPrefix("#") { v.removeFirst() }
        guard v.allSatisfy({ $0.isHexDigit }) else { return nil }
        if v.count == 3 { v = v.map { "\($0)\($0)" }.joined() }
        return v.count == 6 ? "#\(v)" : nil
    }

    /// A #rrggbb color's red, green and blue, 0 to 1; nil for anything else.
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    // MARK: Which screens

    /// A name compared without case and without a trailing slash ("/" stays).
    private static func comparable(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v.count > 1 && v.hasSuffix("/") ? String(v.dropLast()) : v
    }

    /// Whether one rule matches the current screen (the name the app last
    /// passed to `page(_:)`). `*` matches any run of characters; a rule ending
    /// in "/*" also matches the part in front of it.
    static func pageRuleMatches(_ rule: String, _ place: String) -> Bool {
        let r = comparable(rule)
        guard !r.isEmpty else { return false }
        let p = comparable(place)
        if r.hasSuffix("/*") {
            let front = String(r.dropLast(2))
            if comparable(front.isEmpty ? "/" : front) == p { return true }
        }
        let pattern = r.components(separatedBy: "*").map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: [.dotMatchesLineSeparators]) else { return false }
        return regex.firstMatch(in: p, range: NSRange(p.startIndex..<p.endIndex, in: p)) != nil
    }

    /// Whether the bubble shows on this screen. An unknown screen (nil, an
    /// app that never called `page(_:)`) shows nothing under "only" and the
    /// bubble under "except".
    static func bubbleShowsOn(mode: String, rules: [String], place: String?) -> Bool {
        guard mode == "only" || mode == "except" else { return true }
        let hit = place.map { place in rules.contains { pageRuleMatches($0, place) } } ?? false
        return mode == "only" ? hit : !hit
    }

    /// Where the bubble sits before anyone drags it: its distance from the
    /// right and bottom edges of the window.
    static func cornerOffset(
        position: String,
        size: Double,
        width: Double,
        height: Double,
        insets: (top: Double, bottom: Double, left: Double, right: Double),
        margin: Double = 20
    ) -> (x: Double, y: Double) {
        let parts = position.split(separator: "-").map(String.init)
        let top = parts.first == "top"
        let left = parts.last == "left"
        return (
            x: left ? width - size - margin - insets.left : margin + insets.right,
            y: top ? height - size - margin - insets.top : margin + insets.bottom
        )
    }

    /// The bubble's distance from the bottom of the window (4.16.3): at
    /// least `gap` above the safe area plus the app's bottom padding, and at
    /// most `gap` under the top of the safe area. A padding too tall for the
    /// window keeps it just under the top instead of pushing it off screen.
    static func clampedBottom(
        _ y: Double,
        size: Double,
        height: Double,
        insets: (top: Double, bottom: Double),
        padding: Double,
        gap: Double = 8
    ) -> Double {
        let highest = height - size - insets.top - gap
        let lowest = min(insets.bottom + padding + gap, highest)
        return max(lowest, min(highest, y))
    }

    /// Whether the bubble belongs on the app's pages at all: the app asked
    /// for it and the chat is on with its bubble showing. A config that says
    /// the chat is off (a fresh read or the app channel) takes it away.
    static func showsBubble(wanted: Bool, config: Config?) -> Bool {
        guard wanted, let config else { return false }
        return config.enabled && config.showBubble
    }

    // MARK: The app channel

    /// The app's own live channel, for everyone with the bubble on screen:
    /// a change of the owner's on/off switch or of a teammate's Online switch
    /// arrives on it at once as a `config` frame. It needs no key.
    static func appChannelURL(apiUrl: String, appId: String) -> URL? {
        let ws = base(apiUrl).replacingOccurrences(of: "http", with: "ws", options: .anchored)
        return URL(string: "\(ws)/api/live-chat/app-stream?app=\(encode(appId))")
    }

    /// A `config` frame from the app channel: `config` is exactly what
    /// /api/live-chat/config answers, read with the same parser. Also the
    /// JSON to keep as the phone's saved answer. Nil for any other frame.
    static func parseAppFrame(_ text: String) -> (config: Config, saved: Data)? {
        guard let data = text.data(using: .utf8),
              let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              frame["kind"] as? String == "live_chat",
              frame["event"] as? String == "config",
              let inner = frame["config"] as? [String: Any],
              let saved = try? JSONSerialization.data(withJSONObject: inner)
        else { return nil }
        return (parseConfig(saved), saved)
    }

    /// Whether the app channel should be open: the app shows the bubble, it
    /// is in front, the chat is on, and the server has not refused it since
    /// the last config read.
    static func appChannelWanted(wantsBubble: Bool, inFront: Bool, config: Config?, refused: Bool) -> Bool {
        wantsBubble && inFront && !refused && config?.enabled == true
    }

    /// A refusal of the app channel (no such app, or its chat is off): it is
    /// not tried again until a config read says the chat is on. A full
    /// server (429) or a timeout (408) is tried again later.
    static func refusesAppChannel(status: Int?) -> Bool {
        guard let status, (400..<500).contains(status) else { return false }
        return status != 408 && status != 429
    }

    /// The wait before try number `tries` (1 and up) to reach the app
    /// channel again: 2 s doubling up to 60 s, plus up to a quarter more
    /// (`jitter` 0 to 1), so phones do not all come back at once.
    static func appChannelDelay(tries: Int, jitter: Double) -> TimeInterval {
        let base = min(60, 2 * pow(2, Double(max(0, min(tries, 7) - 1))))
        return base * (1 + 0.25 * max(0, min(jitter, 1)))
    }

    static func parseUnread(_ data: Data) -> Int? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let unread = json["unread"] as? Int, unread >= 0
        else { return nil }
        return unread
    }

    /// Whether someone who answers THIS person is online, the affiliate who
    /// brought them included (4.15.0); nil when the answer leaves it out (no
    /// affiliate brought them: the config's online decides).
    static func parseUnreadOnline(_ data: Data) -> Bool? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["online"] as? Bool
    }

    // MARK: The chat page

    /// The chat page for this app. The ids are left out while the person has
    /// opted out of tracking; the token goes in only when there is one.
    /// Without one, `fresh=1` tells the page to drop a token it kept itself
    /// (the last person's, after a sign-out) and start a new thread.
    static func chatURL(env: Env, token: String?, platform: String, language: String, theme: String?, sendColor: String? = nil, placeholder: String? = nil) -> URL? {
        // sheet=1: the page slides up as a sheet (4.15.0) and keeps room for its handle.
        var fragment = ["p=\(platform)", "close=1", "sheet=1"]
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fragment.append("\(key)=\(encode(value))")
        }
        if !env.optedOut {
            add("d", env.deviceId)
            add("v", env.visitorId)
            add("u", env.userId)
        }
        if isToken(token) { add("t", token) } else { fragment.append("fresh=1") }
        add("theme", theme)
        // The send color the app's own code set (the page colors the send
        // arrow and the person's messages with it, over the dashboard's).
        if let sendColor { add("sc", sendColor) }
        // The message box text the app's own code set, in its own language.
        if let placeholder { add("ph", placeholder) }
        return URL(string: "\(base(env.apiUrl))/embed/chat/\(encode(env.appId))?lang=\(encode(language))#\(fragment.joined(separator: "&"))")
    }

    /// The same page without `fresh=1`. It is for the first load only: a
    /// reload must keep the thread the page has started since.
    static func withoutFresh(_ url: URL) -> URL {
        let string = url.absoluteString
        guard let hash = string.firstIndex(of: "#") else { return url }
        let kept = string[string.index(after: hash)...].split(separator: "&").filter { $0 != "fresh=1" }
        return URL(string: String(string[...hash]) + kept.joined(separator: "&")) ?? url
    }

    /// Whether this is THIS app's own chat page (4.15.4, review S18): on the
    /// chat's origin, at exactly /embed/chat/{appId}. Another app's chat page
    /// is not, so it never loads in the sheet, and never hands over a key that
    /// would replace this person's.
    static func isChatPage(_ url: URL, apiUrl: String, appId: String) -> Bool {
        guard isChatOrigin(url, apiUrl: apiUrl),
              let expected = URLComponents(string: "\(base(apiUrl))/embed/chat/\(encode(appId))")?.path,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
        else { return false }
        return path == expected || path == expected + "/"
    }

    /// Whether the address is on the chat's origin: the scheme, host and port of `apiUrl`.
    static func isChatOrigin(_ url: URL, apiUrl: String) -> Bool {
        guard let api = URLComponents(string: base(apiUrl)),
              let other = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = api.scheme?.lowercased(), scheme == "https" || scheme == "http",
              scheme == other.scheme?.lowercased(),
              let host = api.host?.lowercased(), !host.isEmpty, host == other.host?.lowercased()
        else { return false }
        return port(api) == port(other)
    }

    private static func port(_ address: URLComponents) -> Int? {
        if let port = address.port { return port }
        switch address.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    // MARK: What the chat sheet loads (4.15.4, review S18)

    /// Where a navigation the chat page asks for would happen.
    enum Frame: Equatable {
        /// The page itself.
        case main
        /// A frame inside the page.
        case sub
        /// A new window (target="_blank", window.open).
        case newWindow
    }

    /// What the chat sheet does with a navigation.
    enum Navigation: Equatable {
        /// It loads in the sheet.
        case load
        /// A link the person tapped: it opens in the browser, Mail or Phone.
        case openOutside
        /// Nothing happens.
        case block
    }

    /// The sheet's rules for a navigation:
    /// - the page itself loads only this app's own chat page;
    /// - a frame inside it loads only from the chat's origin (and Cloudflare's
    ///   challenge frame, which only shows when Cloudflare checks the visitor
    ///   before serving the chat page);
    /// - anything else leaves the sheet only as a link the person TAPPED (web,
    ///   email or phone), never for a script or a redirect.
    static func navigation(to url: URL, frame: Frame, tapped: Bool, apiUrl: String, appId: String) -> Navigation {
        switch frame {
        case .main:
            if url.absoluteString == "about:blank" || isChatPage(url, apiUrl: apiUrl, appId: appId) { return .load }
        case .sub:
            let address = url.absoluteString
            let inside = address == "about:blank" || address == "about:srcdoc"
                || isChatOrigin(url, apiUrl: apiUrl) || isCloudflareChallenge(url)
            return inside ? .load : .block
        case .newWindow:
            break
        }
        return tapped && opensOutside(url) ? .openOutside : .block
    }

    /// The links the sheet hands to the phone: web pages, email and phone numbers.
    static func opensOutside(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "tel"].contains(scheme)
    }

    /// Cloudflare's own challenge frame (https://challenges.cloudflare.com).
    static func isCloudflareChallenge(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "challenges.cloudflare.com"
    }

    /// One message from the page: a JSON string such as
    /// `{"type":"affiliateo:chat-token","token":"lct_..."}`.
    static func parseHostMessage(_ body: Any) -> HostMessage? {
        let data: Data?
        if let text = body as? String {
            data = text.data(using: .utf8)
        } else if let dict = body as? [String: Any] {
            data = try? JSONSerialization.data(withJSONObject: dict)
        } else {
            data = nil
        }
        guard let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String
        else { return nil }
        switch type {
        case "affiliateo:chat-ready": return .ready
        case "affiliateo:chat-token":
            guard let token = json["token"] as? String, isToken(token) else { return nil }
            return .token(token)
        case "affiliateo:chat-read": return .read
        case "affiliateo:chat-close": return .close
        case "affiliateo:chat-message": return .message
        default: return nil
        }
    }

    /// The red number and the green dot for a circle of `size` points, scaled
    /// from the 56-point bubble's (the website's badgeMetrics; the same numbers).
    struct BadgeMetrics: Equatable {
        let pillHeight: Double
        let pillFont: Double
        let pillPadding: Double
        let pillOffset: Double
        let dot: Double
        let dotOffset: Double
        let border: Double
    }

    static func badgeMetrics(size: Double) -> BadgeMetrics {
        let s = size / 56
        return BadgeMetrics(
            pillHeight: (20 * s).rounded(),
            pillFont: (11 * s * 2).rounded() / 2,
            pillPadding: (5 * s).rounded(),
            pillOffset: (4 * s).rounded(),
            dot: (16 * s).rounded(),
            dotOffset: (2 * s).rounded(),
            border: s < 1 ? 1.5 : 2
        )
    }

    /// The red number on the bubble: up to 9, then "9+".
    static func badgeText(_ unread: Int) -> String? {
        guard unread > 0 else { return nil }
        return unread > 9 ? "9+" : String(unread)
    }

    // MARK: The bubble's words (4.15.2)

    /// What VoiceOver says for the bubble, in the person's language: the 16
    /// languages Affiliateo speaks, English for any other (review E14). The
    /// same words as the website's chat.js and the React Native and Kotlin SDKs.
    struct ChatWords: Equatable {
        let chat: String
        let close: String
        /// "Chat, {n} unread".
        let unreadPattern: String
        /// A notification's line for a message with no text (4.17.0), the
        /// same words the server's push uses.
        let sentMessage: String

        func unread(_ count: Int) -> String {
            unreadPattern.replacingOccurrences(of: "{n}", with: String(count))
        }

        static let all: [String: ChatWords] = [
            "en": ChatWords(chat: "Chat", close: "Close chat", unreadPattern: "Chat, {n} unread", sentMessage: "Sent you a message"),
            "ar": ChatWords(chat: "الدردشة", close: "إغلاق الدردشة", unreadPattern: "الدردشة، {n} غير مقروءة", sentMessage: "أرسل لك رسالة"),
            "de": ChatWords(chat: "Chat", close: "Chat schließen", unreadPattern: "Chat, {n} ungelesen", sentMessage: "Hat dir eine Nachricht gesendet"),
            "es": ChatWords(chat: "Chat", close: "Cerrar chat", unreadPattern: "Chat, {n} sin leer", sentMessage: "Te envió un mensaje"),
            "fr": ChatWords(chat: "Chat", close: "Fermer le chat", unreadPattern: "Chat, {n} non lus", sentMessage: "Vous a envoyé un message"),
            "hi": ChatWords(chat: "चैट", close: "चैट बंद करें", unreadPattern: "चैट, {n} अपठित", sentMessage: "आपको एक संदेश भेजा"),
            "it": ChatWords(chat: "Chat", close: "Chiudi chat", unreadPattern: "Chat, {n} non letti", sentMessage: "Ti ha inviato un messaggio"),
            "ja": ChatWords(chat: "チャット", close: "チャットを閉じる", unreadPattern: "チャット、未読 {n} 件", sentMessage: "メッセージが届きました"),
            "ko": ChatWords(chat: "채팅", close: "채팅 닫기", unreadPattern: "채팅, 읽지 않음 {n}개", sentMessage: "메시지를 보냈습니다"),
            "nl": ChatWords(chat: "Chat", close: "Chat sluiten", unreadPattern: "Chat, {n} ongelezen", sentMessage: "Heeft je een bericht gestuurd"),
            "pl": ChatWords(chat: "Czat", close: "Zamknij czat", unreadPattern: "Czat, nieprzeczytane: {n}", sentMessage: "Masz nową wiadomość"),
            "pt": ChatWords(chat: "Chat", close: "Fechar chat", unreadPattern: "Chat, {n} não lidas", sentMessage: "Enviou uma mensagem para você"),
            "ru": ChatWords(chat: "Чат", close: "Закрыть чат", unreadPattern: "Чат, непрочитанных: {n}", sentMessage: "Вам пришло сообщение"),
            "tr": ChatWords(chat: "Sohbet", close: "Sohbeti kapat", unreadPattern: "Sohbet, {n} okunmamış", sentMessage: "Size bir mesaj gönderdi"),
            "vi": ChatWords(chat: "Trò chuyện", close: "Đóng trò chuyện", unreadPattern: "Trò chuyện, {n} chưa đọc", sentMessage: "Đã gửi cho bạn một tin nhắn"),
            "zh": ChatWords(chat: "聊天", close: "关闭聊天", unreadPattern: "聊天，{n} 条未读", sentMessage: "给你发了一条消息"),
        ]

        /// The words for a language tag ("pt-BR", "zh-Hans-CN"): its first two letters.
        static func forLanguage(_ tag: String) -> ChatWords {
            all[String(tag.lowercased().prefix(2))] ?? all["en"]!
        }
    }

    // MARK: The wiggle (4.17.0)

    /// The shortest and the longest time between two wiggles, in seconds.
    static let wiggleMinSeconds = 3
    static let wiggleMaxSeconds = 3600
    /// One wiggle lasts this long. The motion below is the one the website's
    /// bubble and the other SDKs play (KEEP IN STEP): the whole bubble turns
    /// around its center and grows a touch, as one piece.
    static let wiggleDuration: TimeInterval = 0.9
    /// How many even steps the animation is drawn in: one for each frame of
    /// a 120 Hz screen, with a straight step between two of them. The first
    /// version had seven turns, each easing to a stop, which looked jerky.
    static let wiggleSteps = 108

    /// The turn, in degrees, at progress `p` (0 at the start, 1 at the end):
    /// three full left and right swings that die down smoothly, the first
    /// about 14 degrees, the last about 1.
    static func wiggleAngle(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        return 16 * sin(6 * Double.pi * p) * pow(1 - p, 1.2)
    }

    /// The size at progress `p`: it grows a touch (to 1.06) and settles back.
    static func wiggleScale(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 1 }
        return 1 + 0.06 * sin(Double.pi * p)
    }

    /// One wiggle as the animation plays it: the turn (degrees) and the size
    /// at `steps` + 1 evenly spaced moments, from rest to rest.
    static func wiggleCurve(steps: Int = ChatRules.wiggleSteps) -> (angles: [Double], scales: [Double]) {
        let count = max(steps, 1)
        let moments = (0...count).map { Double($0) / Double(count) }
        return (moments.map { wiggleAngle($0) }, moments.map { wiggleScale($0) })
    }

    /// The config's `bubble.wiggle_seconds`: seconds between two wiggles,
    /// 0 for off. A config without the field (a server from before the
    /// wiggle), or with something that is not a number, a negative one or
    /// NaN, does not wiggle; a positive number below 3 is 3.
    static func wiggleSeconds(_ raw: Any?) -> Int {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(max(Int(min(seconds, Double(wiggleMaxSeconds))), wiggleMinSeconds), wiggleMaxSeconds)
    }

    /// What `setChatBubbleWiggle(seconds:)` keeps: 0 (off) for nil, 0 or
    /// less, otherwise the seconds, 3 at least.
    static func wiggleOverride(_ seconds: Int?) -> Int {
        guard let seconds, seconds > 0 else { return 0 }
        return min(max(seconds, wiggleMinSeconds), wiggleMaxSeconds)
    }

    /// Seconds between two wiggles (0 for none): the app's own choice once
    /// it made one with `setChatBubbleWiggle(seconds:)`, else the dashboard's.
    static func wiggleEvery(override: Int?, config: Config?) -> Int {
        override ?? config?.bubble.wiggleSeconds ?? 0
    }

    /// Whether the bubble wiggles now: only while it is on screen, the chat
    /// is closed, the app is in front and nobody is dragging it, and never
    /// with Reduce Motion on.
    static func wigglesNow(every seconds: Int, bubbleShown: Bool, chatOpen: Bool, inFront: Bool, dragging: Bool, reduceMotion: Bool) -> Bool {
        seconds > 0 && bubbleShown && !chatOpen && inFront && !dragging && !reduceMotion
    }

    // MARK: Notifications (4.17.0)

    /// Where a chat notification keeps its own details in `userInfo`: in a
    /// push from Affiliateo and in the notifications the SDK posts itself.
    static let noticeKey = "affiliateo_chat"
    /// Chat notifications stack together, as one conversation's do in Messages.
    static let noticeThread = "affiliateo-chat"
    /// A message is cut to about this many characters, as the server's push is.
    static let noticeBodyLimit = 180

    /// A chat notification's details.
    struct Notice: Equatable {
        var app: String?
        var conversationId: String?
        var messageId: String?
        /// Set on the greeting's notification.
        var greetingId: String?
    }

    /// The chat notification in a notification's `userInfo`, or nil when
    /// the notification is not one of the chat's.
    static func notice(_ userInfo: [AnyHashable: Any]) -> Notice? {
        guard let raw = userInfo[noticeKey] as? [String: Any] else { return nil }
        return Notice(
            app: text(raw["app"]),
            conversationId: text(raw["conversation_id"]),
            messageId: text(raw["message_id"]),
            greetingId: text(raw["greeting_id"])
        )
    }

    /// The `userInfo` of a notification the SDK posts itself: the same shape
    /// a push from Affiliateo has.
    static func noticeInfo(_ notice: Notice) -> [String: Any] {
        var inner: [String: Any] = [:]
        if let app = notice.app { inner["app"] = app }
        if let id = notice.conversationId { inner["conversation_id"] = id }
        if let id = notice.messageId { inner["message_id"] = id }
        if let id = notice.greetingId { inner["greeting_id"] = id }
        return [noticeKey: inner]
    }

    /// How a notification that arrives while the app is open shows.
    enum NoticeShow: Equatable {
        /// Not one of the chat's: the app decides.
        case notOurs
        /// The chat is open on screen: the message is already in front of the person.
        case quiet
        /// A banner with its sound, kept in the list, like a message.
        case banner
    }

    static func noticeShow(_ userInfo: [AnyHashable: Any], chatOpen: Bool) -> NoticeShow {
        guard notice(userInfo) != nil else { return .notOurs }
        return chatOpen ? .quiet : .banner
    }

    /// A notification's line for a message: its text, cut to about 180
    /// characters. A message with no text says "Sent you a message" in the
    /// person's language.
    static func noticeBody(_ text: String?, language: String) -> String {
        let clean = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return ChatWords.forLanguage(language).sentMessage }
        guard clean.count > noticeBodyLimit else { return clean }
        return String(clean.prefix(noticeBodyLimit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The greeting as the chat window would show it to this person: their
    /// language's version when the config carries one, else the main text.
    static func greetingText(_ config: Config, language: String) -> String? {
        config.greetings[String(language.lowercased().prefix(2))] ?? config.greeting
    }

    /// Whether the greeting goes out as a notification now: the app said
    /// notifications are allowed, the greeting still counts as unread (the
    /// same rule as the red 1: on, never seen, no thread yet), there are
    /// words to show, the chat is closed, and this greeting has not gone
    /// out on this install before.
    static func greetingNoticeDue(allowed: Bool, config: Config?, pending: Bool, notifiedId: String?, chatOpen: Bool, language: String) -> Bool {
        guard allowed, pending, !chatOpen, let config, config.enabled,
              let id = config.bubble.greetingId, greetingText(config, language: language) != nil
        else { return false }
        return notifiedId != id
    }

    /// A team message as it arrives on the thread's socket.
    struct TeamMessage: Equatable {
        var id: String?
        var conversationId: String?
        var body: String
    }

    /// The team's message in a socket frame, or nil for any other frame.
    static func teamMessage(_ frame: [String: Any]) -> TeamMessage? {
        guard frame["kind"] as? String == "live_chat", frame["event"] as? String == "message",
              let message = frame["message"] as? [String: Any], message["sender"] as? String == "team"
        else { return nil }
        return TeamMessage(id: text(message["id"]), conversationId: text(frame["conversation_id"]), body: message["body"] as? String ?? "")
    }

    /// Whether the SDK posts a notification of its own for a team message
    /// that arrived on the socket: only while the app is in front with the
    /// chat closed, and only when this install has no push token registered.
    /// A registered phone gets Affiliateo's push for the same message, which
    /// the app shows through `chatNotificationPresentation(for:)`.
    static func postsLocalNotice(inFront: Bool, chatOpen: Bool, pushRegistered: Bool) -> Bool {
        inFront && !chatOpen && !pushRegistered
    }

    /// An id as text, whether the JSON had it as text or as a number.
    private static func text(_ raw: Any?) -> String? {
        if let text = raw as? String { return text.isEmpty ? nil : text }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    // MARK: The push token (4.17.0)

    /// Where a phone is registered (POST) and forgotten (DELETE).
    static func pushDevicesURL(apiUrl: String) -> URL? {
        URL(string: "\(base(apiUrl))/api/live-chat/push-devices")
    }

    /// Apple's device token as the server takes it: lowercase hex.
    static func pushToken(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// What the server keeps about this phone so a reply can reach it.
    struct PushDevice: Equatable, Codable {
        var app: String
        var token: String
        var bundleId: String
        /// Apple's push service for this build: "sandbox" or "production".
        var environment: String
        /// The same device id the chat page sends, which the server matches
        /// a thread to its phone by.
        var deviceId: String
        var userId: String?
        var language: String
    }

    /// The phone to register, or nil while there is nothing to register: no
    /// token from the app yet, the chat not (known to be) on for this app,
    /// or the person opted out of tracking (the chat then carries no device
    /// id, so no reply could find the phone).
    static func pushDevice(env: Env, config: Config?, token: String?, bundleId: String?, environment: String, language: String) -> PushDevice? {
        guard let token, !token.isEmpty, config?.enabled == true, !env.optedOut,
              let deviceId = env.deviceId, !deviceId.isEmpty,
              let bundleId, !bundleId.isEmpty
        else { return nil }
        return PushDevice(app: env.appId, token: token, bundleId: bundleId, environment: environment, deviceId: deviceId, userId: env.userId, language: language)
    }

    /// The JSON of POST /api/live-chat/push-devices. The visitor id goes
    /// along when the SDK has it; it is a label, not what a phone is found by.
    static func pushDeviceBody(_ device: PushDevice, visitorId: String?) -> [String: Any] {
        var body: [String: Any] = [
            "app": device.app,
            "platform": "ios",
            "token": device.token,
            "bundle_id": device.bundleId,
            "environment": device.environment,
            "device_id": device.deviceId,
            "language": device.language,
        ]
        if let visitorId, !visitorId.isEmpty { body["visitor_id"] = visitorId }
        if let userId = device.userId, !userId.isEmpty { body["user_id"] = userId }
        return body
    }

    /// A request that got no answer (the phone was offline) is not sent
    /// again sooner than this.
    static let pushRetryAfter: TimeInterval = 5 * 60

    /// Whether the server needs to hear about this phone (again): once each
    /// launch (the same token again switches a phone the server had dropped
    /// back on), and when the token, the app, the language or the signed-in
    /// user changes. `answered` is the registration the server has answered
    /// in this launch, whatever it said: nothing is sent in a loop.
    static func pushRegistrationDue(answered: PushDevice?, next: PushDevice) -> Bool {
        answered != next
    }

    /// What became of a request to /api/live-chat/push-devices.
    enum PushAnswer: Equatable {
        /// `200 { "ok": true }`: stored (or forgotten).
        case ok
        /// `200 { "ok": false }`: an app the server does not know, one whose
        /// chat is off, or something it cannot use. Nothing is stored.
        case notTaken
        /// Any other answer (429, 5xx, a server from before the route):
        /// left until the next launch.
        case failed
        /// No answer at all (offline, a time out): tried again later.
        case noAnswer
    }

    static func pushAnswer(status: Int?, body: Data?) -> PushAnswer {
        guard let status else { return .noAnswer }
        guard status == 200 else { return .failed }
        return body.map(parseOk) == true ? .ok : .notTaken
    }

    /// The server's `{ "ok": true }`.
    static func parseOk(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["ok"] as? Bool == true
    }

    /// Apple's push service for this build, "sandbox" or "production", from
    /// how it was signed: the Simulator and a build with a development
    /// profile use the sandbox; a build with a distribution profile, and an
    /// App Store or TestFlight build (which carries no profile), production.
    /// A profile that cannot be read goes by the build's configuration.
    static func apnsEnvironment(profile: Data?, simulator: Bool, debugBuild: Bool) -> String {
        if simulator { return "sandbox" }
        guard let profile else { return "production" }
        switch apsEnvironment(inProfile: profile) {
        case "development": return "sandbox"
        case "production": return "production"
        default: return debugBuild ? "sandbox" : "production"
        }
    }

    /// The `aps-environment` entitlement inside a provisioning profile
    /// (embedded.mobileprovision: a signed envelope around a property list).
    static func apsEnvironment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["aps-environment"] as? String
    }

    // MARK: Helpers

    private static func base(_ apiUrl: String) -> String {
        apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
    }

    /// encodeURIComponent: everything but letters, digits and `-._~!*'()`.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~!*'()")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

/// Counts sign-outs and switches of person (4.15.1), readable from any
/// thread. The chat screen saves a thread key the page hands over only while
/// the count is still the one it opened with, so a key can never outlive a
/// sign-out: `logout()` bumps it before anything else, on the caller's thread.
enum ChatSignOuts {
    private static let lock = NSLock()
    private static var count = 0

    static var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    static func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Whether the chat is open on screen (4.17.0), readable from any thread:
/// iOS asks how to show a notification on whatever thread the app's
/// notification delegate runs on, and a reply needs no banner over the very
/// chat it is in.
enum ChatOnScreen {
    private static let lock = NSLock()
    private static var open = false

    static var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    static func set(_ value: Bool) {
        lock.lock()
        open = value
        lock.unlock()
    }
}
