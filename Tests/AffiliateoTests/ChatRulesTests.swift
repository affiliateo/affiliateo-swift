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
        XCTAssertNil(parts["fresh"])
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

    func testNoTokenAsksForAFreshThread() {
        // After a sign-out the page must drop the token it kept itself.
        XCTAssertEqual(fragment(ChatRules.chatURL(env: env(), token: nil, platform: "ios", language: "en", theme: nil))["fresh"], "1")
        XCTAssertEqual(fragment(ChatRules.chatURL(env: env(), token: "lct_bad", platform: "ios", language: "en", theme: nil))["fresh"], "1")
        XCTAssertEqual(fragment(ChatRules.chatURL(env: env(optedOut: true), token: nil, platform: "ios", language: "en", theme: nil))["fresh"], "1")
        XCTAssertNil(fragment(ChatRules.chatURL(env: env(optedOut: true), token: token, platform: "ios", language: "en", theme: nil))["fresh"])
    }

    func testAReloadKeepsTheThreadTheFirstLoadStarted() {
        let first = ChatRules.chatURL(env: env(), token: nil, platform: "ios", language: "en", theme: "dark")!
        let again = ChatRules.withoutFresh(first)
        XCTAssertNil(fragment(again)["fresh"])
        XCTAssertEqual(fragment(again)["theme"], "dark")
        XCTAssertEqual(fragment(again)["u"], "user 1&2")
        XCTAssertEqual(again.absoluteString, first.absoluteString.replacingOccurrences(of: "&fresh=1", with: ""))
        let withToken = ChatRules.chatURL(env: env(), token: token, platform: "ios", language: "en", theme: nil)!
        XCTAssertEqual(ChatRules.withoutFresh(withToken), withToken)
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

    // The website's bubble-options.test.ts cases: a bubble must show on the
    // same pages and screens everywhere.
    func testPageRules() {
        let cases: [(String, String, Bool)] = [
            ("/pricing", "/pricing", true),
            ("/pricing", "/Pricing/", true),
            ("/pricing", "/pricing/plans", false),
            ("/blog/*", "/blog/my-post", true),
            ("/blog/*", "/blog/", true),
            ("/blog/*", "/blog", true),
            ("/blog/*", "/blogger", false),
            ("/*", "/", true),
            ("/blog*", "/blog", true),
            ("*/checkout", "/shop/checkout", true),
            ("/", "/", true),
            ("/", "/about", false),
            ("Settings", "settings", true),
            ("Paywall*", "PaywallAnnual", true),
            ("Paywall*", "Home", false),
            ("/a.b", "/axb", false),
            ("/(x)", "/(x)", true),
            ("", "/", false),
            ("   ", "/", false),
        ]
        for (rule, place, expected) in cases {
            XCTAssertEqual(ChatRules.pageRuleMatches(rule, place), expected, "\(rule) against \(place)")
        }
    }

    func testBubbleShowsOn() {
        let rules = ["/checkout*", "Paywall*"]
        XCTAssertTrue(ChatRules.bubbleShowsOn(mode: "all", rules: rules, place: "/checkout"))
        XCTAssertTrue(ChatRules.bubbleShowsOn(mode: "all", rules: [], place: nil))
        XCTAssertTrue(ChatRules.bubbleShowsOn(mode: "only", rules: rules, place: "/checkout/step-2"))
        XCTAssertFalse(ChatRules.bubbleShowsOn(mode: "only", rules: rules, place: "/home"))
        XCTAssertFalse(ChatRules.bubbleShowsOn(mode: "only", rules: rules, place: nil))
        XCTAssertFalse(ChatRules.bubbleShowsOn(mode: "except", rules: rules, place: "PaywallYearly"))
        XCTAssertTrue(ChatRules.bubbleShowsOn(mode: "except", rules: rules, place: "Home"))
        XCTAssertTrue(ChatRules.bubbleShowsOn(mode: "except", rules: rules, place: nil))
    }

    func testBubbleConfig() {
        let json = #"{"enabled":true,"show_bubble":true,"online":false,"bubble":{"position":"top-left","size":"large","size_points":64,"page_mode":"except","page_rules":["Paywall*",3],"greeting_id":"e40c292c"}}"#
        let config = ChatRules.parseConfig(Data(json.utf8))
        XCTAssertEqual(config.bubble.position, "top-left")
        XCTAssertEqual(config.bubble.size, 64)
        XCTAssertEqual(config.bubble.pageMode, "except")
        XCTAssertEqual(config.bubble.pageRules, ["Paywall*"])
        XCTAssertEqual(config.bubble.greetingId, "e40c292c")
        // An older server, or odd values: the old fixed bubble.
        let plain = ChatRules.parseConfig(Data(#"{"enabled":true,"show_bubble":true,"bubble":{"position":"middle","size_points":500,"page_mode":"x"}}"#.utf8))
        XCTAssertEqual(plain.bubble, ChatRules.Bubble.standard)
    }

    func testCornerOffset() {
        let insets = (top: 59.0, bottom: 34.0, left: 0.0, right: 0.0)
        let br = ChatRules.cornerOffset(position: "bottom-right", size: 56, width: 440, height: 956, insets: insets)
        XCTAssertEqual(br.x, 20)
        XCTAssertEqual(br.y, 54)
        let tl = ChatRules.cornerOffset(position: "top-left", size: 48, width: 440, height: 956, insets: insets)
        XCTAssertEqual(tl.x, 440 - 48 - 20)
        XCTAssertEqual(tl.y, 956 - 48 - 20 - 59)
    }

    func testColors() {
        let colored = ChatRules.parseConfig(Data(##"{"enabled":true,"bubble":{"color":"#7c3aed","icon_color":"#fef3c7"}}"##.utf8))
        XCTAssertEqual(colored.bubble.color, "#7c3aed")
        XCTAssertEqual(colored.bubble.iconColor, "#fef3c7")
        // Anything that is not #rrggbb keeps Affiliateo's blue and white.
        let odd = ChatRules.parseConfig(Data(##"{"enabled":true,"bubble":{"color":"purple","icon_color":"#fff"}}"##.utf8))
        XCTAssertEqual(odd.bubble.color, "#1754d8")
        XCTAssertEqual(odd.bubble.iconColor, "#ffffff")
        XCTAssertEqual(ChatRules.rgb("#ff8000")?.g ?? 0, 128.0 / 255, accuracy: 0.0001)
    }

    func testGlassStyle() {
        let glass = ChatRules.parseConfig(Data(#"{"enabled":true,"bubble":{"style":"glass"}}"#.utf8))
        XCTAssertEqual(glass.bubble.style, "glass")
        // Anything else, or a server from before the style, is the blue circle.
        XCTAssertEqual(ChatRules.parseConfig(Data(#"{"enabled":true,"bubble":{"style":"neon"}}"#.utf8)).bubble.style, "standard")
        XCTAssertEqual(ChatRules.parseConfig(Data(#"{"enabled":true,"bubble":{}}"#.utf8)).bubble.style, "standard")
    }

    func testSizesAndBadges() {
        let auto = ChatRules.parseConfig(Data(#"{"enabled":true,"bubble":{"size":"auto","size_points":56,"size_points_phone":48}}"#.utf8))
        XCTAssertEqual(auto.bubble.size, 56)
        XCTAssertEqual(auto.bubble.sizePhone, 48)
        // A server from before the phone size: both are size_points.
        let old = ChatRules.parseConfig(Data(#"{"enabled":true,"bubble":{"size":"large","size_points":64}}"#.utf8))
        XCTAssertEqual(old.bubble.sizePhone, 64)
        // The website's pinned numbers (bubble-options.test.ts).
        XCTAssertEqual(ChatRules.badgeMetrics(size: 56), .init(pillHeight: 20, pillFont: 11, pillPadding: 5, pillOffset: 4, dot: 16, dotOffset: 2, border: 2))
        XCTAssertEqual(ChatRules.badgeMetrics(size: 48), .init(pillHeight: 17, pillFont: 9.5, pillPadding: 4, pillOffset: 3, dot: 14, dotOffset: 2, border: 1.5))
        XCTAssertEqual(ChatRules.badgeMetrics(size: 64), .init(pillHeight: 23, pillFont: 12.5, pillPadding: 6, pillOffset: 5, dot: 18, dotOffset: 2, border: 2))
    }
}
