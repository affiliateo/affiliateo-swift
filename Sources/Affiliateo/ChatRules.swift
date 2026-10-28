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

    // MARK: Storage, the same key names as the React Native SDK

    static func tokenKey(_ appId: String) -> String { "affiliateo_chat_token_\(appId)" }
    static func positionKey(_ appId: String) -> String { "affiliateo_chat_pos_\(appId)" }
    static func greetingKey(_ appId: String) -> String { "affiliateo_chat_greeting_seen_\(appId)" }
    /// The server's last answer about the chat (4.15.0): the bubble shows from
    /// it at once on the next launch while a fresh one is asked for.
    static func configKey(_ appId: String) -> String { "affiliateo_chat_config_\(appId)" }

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
        return Config(
            enabled: true,
            showBubble: json["show_bubble"] as? Bool == true,
            online: json["online"] as? Bool == true,
            bubble: parseBubble(json["bubble"])
        )
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
        return bubble
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

    static func parseUnread(_ data: Data) -> Int? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let unread = json["unread"] as? Int, unread >= 0
        else { return nil }
        return unread
    }

    // MARK: The chat page

    /// The chat page for this app. The ids are left out while the person has
    /// opted out of tracking; the token goes in only when there is one.
    /// Without one, `fresh=1` tells the page to drop a token it kept itself
    /// (the last person's, after a sign-out) and start a new thread.
    static func chatURL(env: Env, token: String?, platform: String, language: String, theme: String?) -> URL? {
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

    /// Whether the web view may load this address itself. Anything else is a
    /// link the business sent, which opens in the browser so the chat stays.
    static func isChatPage(_ url: URL, apiUrl: String) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        return url.absoluteString.hasPrefix("\(base(apiUrl))/embed/chat/")
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
