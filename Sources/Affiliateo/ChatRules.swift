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

        static let off = Config(enabled: false, showBubble: false, online: false)
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
            online: json["online"] as? Bool == true
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
    static func chatURL(env: Env, token: String?, platform: String, language: String, theme: String?) -> URL? {
        var fragment = ["p=\(platform)", "close=1"]
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fragment.append("\(key)=\(encode(value))")
        }
        if !env.optedOut {
            add("d", env.deviceId)
            add("v", env.visitorId)
            add("u", env.userId)
        }
        if isToken(token) { add("t", token) }
        add("theme", theme)
        return URL(string: "\(base(env.apiUrl))/embed/chat/\(encode(env.appId))?lang=\(encode(language))#\(fragment.joined(separator: "&"))")
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
