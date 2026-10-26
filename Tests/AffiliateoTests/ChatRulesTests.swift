import XCTest
@testable import Affiliateo

final class ChatRulesTests: XCTestCase {
    private let token = "lct_" + String(repeating: "A", count: 42) + "_"

    private func env(optedOut: Bool = false, userId: String? = "user 1&2") -> ChatRules.Env {
        ChatRules.Env(
            appId: "my-app",
            apiUrl: "https://affiliateo.com/",
            deviceId: "ios-ABC",
            visitorId: "v_123",
            userId: userId,
            optedOut: optedOut,
            debug: false
        )
    }

    private func fragment(_ url: URL?) -> [String: String] {
        var parts: [String: String] = [:]
        for pair in (url?.fragment ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            parts[kv[0]] = kv.count > 1 ? kv[1].removingPercentEncoding : ""
        }
        return parts
    }

    func testTokenShape() {
        XCTAssertTrue(ChatRules.isToken(token))
        XCTAssertFalse(ChatRules.isToken(nil))
        XCTAssertFalse(ChatRules.isToken("lct_short"))
        XCTAssertFalse(ChatRules.isToken(token + "x"))
        XCTAssertFalse(ChatRules.isToken("abc_" + String(repeating: "A", count: 43)))
    }

    func testChatPageCarriesTheIdsInTheFragment() {
        let url = ChatRules.chatURL(env: env(), token: token, platform: "ios", language: "pt-BR", theme: "dark")
        XCTAssertEqual(url?.host, "affiliateo.com")
        XCTAssertEqual(url?.path, "/embed/chat/my-app")
        XCTAssertEqual(url?.query, "lang=pt-BR")
        let parts = fragment(url)
        XCTAssertEqual(parts["p"], "ios")
        XCTAssertEqual(parts["close"], "1")
        XCTAssertEqual(parts["d"], "ios-ABC")
        XCTAssertEqual(parts["v"], "v_123")
        XCTAssertEqual(parts["u"], "user 1&2")
        XCTAssertEqual(parts["t"], token)
        XCTAssertEqual(parts["theme"], "dark")
        // The user id's & and space are escaped, not read as separators.
        XCTAssertTrue(url?.absoluteString.contains("u=user%201%262") ?? false)
    }

    func testOptedOutLeavesTheIdsOut() {
        let parts = fragment(ChatRules.chatURL(env: env(optedOut: true), token: token, platform: "ios", language: "en", theme: nil))
        XCTAssertNil(parts["d"])
        XCTAssertNil(parts["v"])
        XCTAssertNil(parts["u"])
        XCTAssertEqual(parts["t"], token)
        XCTAssertNil(parts["theme"])
    }

    func testNoTokenNoT() {
        XCTAssertNil(fragment(ChatRules.chatURL(env: env(), token: nil, platform: "ios", language: "en", theme: nil))["t"])
        XCTAssertNil(fragment(ChatRules.chatURL(env: env(), token: "lct_bad", platform: "ios", language: "en", theme: nil))["t"])
    }

    func testOnlyTheChatPageLoadsInside() {
        let api = "https://affiliateo.com"
        XCTAssertTrue(ChatRules.isChatPage(URL(string: "https://affiliateo.com/embed/chat/my-app?lang=en#p=ios")!, apiUrl: api))
        XCTAssertTrue(ChatRules.isChatPage(URL(string: "about:blank")!, apiUrl: api))
        XCTAssertFalse(ChatRules.isChatPage(URL(string: "https://affiliateo.com/pricing")!, apiUrl: api))
        XCTAssertFalse(ChatRules.isChatPage(URL(string: "https://affiliateo.com.evil.example/embed/chat/x")!, apiUrl: api))
        XCTAssertFalse(ChatRules.isChatPage(URL(string: "https://example.com/")!, apiUrl: api))
    }

    func testConfig() {
        let on = ChatRules.parseConfig(Data(#"{"enabled":true,"show_bubble":false,"online":true}"#.utf8))
        XCTAssertEqual(on, ChatRules.Config(enabled: true, showBubble: false, online: true))
        XCTAssertEqual(ChatRules.parseConfig(Data(#"{"enabled":false,"show_bubble":true}"#.utf8)), .off)
        XCTAssertEqual(ChatRules.parseConfig(Data("not json".utf8)), .off)
    }

    func testUnread() {
        XCTAssertEqual(ChatRules.parseUnread(Data(#"{"unread":3}"#.utf8)), 3)
        XCTAssertNil(ChatRules.parseUnread(Data(#"{"unread":-1}"#.utf8)))
        XCTAssertNil(ChatRules.parseUnread(Data("{}".utf8)))
    }

    func testBadge() {
        XCTAssertNil(ChatRules.badgeText(0))
        XCTAssertEqual(ChatRules.badgeText(4), "4")
        XCTAssertEqual(ChatRules.badgeText(12), "9+")
    }

    func testMessagesFromThePage() {
        XCTAssertEqual(ChatRules.parseHostMessage(#"{"type":"affiliateo:chat-token","token":"\#(token)"}"#), .token(token))
        XCTAssertNil(ChatRules.parseHostMessage(#"{"type":"affiliateo:chat-token","token":"lct_bad"}"#))
        XCTAssertEqual(ChatRules.parseHostMessage(#"{"type":"affiliateo:chat-close"}"#), .close)
        XCTAssertEqual(ChatRules.parseHostMessage(#"{"type":"affiliateo:chat-read"}"#), .read)
        XCTAssertEqual(ChatRules.parseHostMessage(#"{"type":"affiliateo:chat-ready"}"#), .ready)
        XCTAssertEqual(ChatRules.parseHostMessage(["type": "affiliateo:chat-message"]), .message)
        XCTAssertNil(ChatRules.parseHostMessage(#"{"type":"something-else"}"#))
        XCTAssertNil(ChatRules.parseHostMessage(42))
    }
}
