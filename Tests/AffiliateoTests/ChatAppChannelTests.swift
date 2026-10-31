import XCTest
@testable import Affiliateo

/// The app channel: the owner's on/off switch and the team's Online switches
/// reach the bubble at once, as a `config` frame holding exactly what
/// /api/live-chat/config answers.
final class ChatAppChannelTests: XCTestCase {
    private let onFrame = #"""
    {"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":true,"show_bubble":true,"online":true,"bubble":{"position":"top-left","size_points":64,"size_points_phone":48,"page_mode":"only","page_rules":["Home"],"greeting_id":"g2","style":"glass","color":"#7c3aed","icon_color":"#000000"}}}
    """#
    private let offFrame = #"{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":false,"show_bubble":false}}"#

    func testTheAddressNamesTheAppAndCarriesNoKey() {
        XCTAssertEqual(
            ChatRules.appChannelURL(apiUrl: "https://affiliateo.com/", appId: "my app&1")?.absoluteString,
            "wss://affiliateo.com/api/live-chat/app-stream?app=my%20app%261"
        )
        XCTAssertEqual(
            ChatRules.appChannelURL(apiUrl: "http://localhost:3000", appId: "a1")?.absoluteString,
            "ws://localhost:3000/api/live-chat/app-stream?app=a1"
        )
    }

    func testAConfigFrameReadsAsAFreshConfigRead() {
        let frame = ChatRules.parseAppFrame(onFrame)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.config.enabled, true)
        XCTAssertEqual(frame?.config.showBubble, true)
        XCTAssertEqual(frame?.config.online, true)
        XCTAssertEqual(frame?.config.bubble.position, "top-left")
        XCTAssertEqual(frame?.config.bubble.size, 64)
        XCTAssertEqual(frame?.config.bubble.sizePhone, 48)
        XCTAssertEqual(frame?.config.bubble.pageMode, "only")
        XCTAssertEqual(frame?.config.bubble.pageRules, ["Home"])
        XCTAssertEqual(frame?.config.bubble.greetingId, "g2")
        XCTAssertEqual(frame?.config.bubble.style, "glass")
        XCTAssertEqual(frame?.config.bubble.color, "#7c3aed")
        // The same parser as the GET: the saved copy reads back the same.
        XCTAssertEqual(frame.map { ChatRules.parseConfig($0.saved) }, frame?.config)
    }

    func testOffTakesTheBubbleAway() {
        let frame = ChatRules.parseAppFrame(offFrame)
        XCTAssertEqual(frame?.config, .off)
        XCTAssertFalse(ChatRules.showsBubble(wanted: true, config: frame?.config))
        XCTAssertTrue(ChatRules.showsBubble(wanted: true, config: ChatRules.parseAppFrame(onFrame)?.config))
        XCTAssertFalse(ChatRules.showsBubble(wanted: false, config: ChatRules.parseAppFrame(onFrame)?.config))
        XCTAssertFalse(ChatRules.showsBubble(wanted: true, config: nil))
        // On, but hidden until someone is online: no bubble, the channel stays.
        let hidden = ChatRules.Config(enabled: true, showBubble: false, online: false)
        XCTAssertFalse(ChatRules.showsBubble(wanted: true, config: hidden))
        XCTAssertTrue(ChatRules.appChannelWanted(wantsBubble: true, inFront: true, config: hidden, refused: false))
    }

    func testOtherFramesAreNotConfig() {
        XCTAssertNil(ChatRules.parseAppFrame("pong"))
        XCTAssertNil(ChatRules.parseAppFrame("not json"))
        XCTAssertNil(ChatRules.parseAppFrame(#"{"kind":"live_chat","event":"message","config":{"enabled":true}}"#))
        XCTAssertNil(ChatRules.parseAppFrame(#"{"kind":"message","event":"config","config":{"enabled":true}}"#))
        XCTAssertNil(ChatRules.parseAppFrame(#"{"kind":"live_chat","event":"config","config":true}"#))
        // An odd config inside a config frame is off, as a GET would read it.
        XCTAssertEqual(ChatRules.parseAppFrame(#"{"kind":"live_chat","event":"config","config":{}}"#)?.config, .off)
    }

    func testWhenTheChannelIsOpen() {
        let on = ChatRules.Config(enabled: true, showBubble: true, online: false)
        XCTAssertTrue(ChatRules.appChannelWanted(wantsBubble: true, inFront: true, config: on, refused: false))
        XCTAssertFalse(ChatRules.appChannelWanted(wantsBubble: false, inFront: true, config: on, refused: false))
        XCTAssertFalse(ChatRules.appChannelWanted(wantsBubble: true, inFront: false, config: on, refused: false))
        XCTAssertFalse(ChatRules.appChannelWanted(wantsBubble: true, inFront: true, config: .off, refused: false))
        XCTAssertFalse(ChatRules.appChannelWanted(wantsBubble: true, inFront: true, config: nil, refused: false))
        XCTAssertFalse(ChatRules.appChannelWanted(wantsBubble: true, inFront: true, config: on, refused: true))
    }

    func testARefusalWaitsForTheNextConfigRead() {
        XCTAssertTrue(ChatRules.refusesAppChannel(status: 404))
        XCTAssertTrue(ChatRules.refusesAppChannel(status: 403))
        XCTAssertFalse(ChatRules.refusesAppChannel(status: 429))
        XCTAssertFalse(ChatRules.refusesAppChannel(status: 408))
        XCTAssertFalse(ChatRules.refusesAppChannel(status: 503))
        XCTAssertFalse(ChatRules.refusesAppChannel(status: 101))
        XCTAssertFalse(ChatRules.refusesAppChannel(status: nil))
    }

    func testBackoffDoublesFromTwoSecondsToAMinutePlusJitter() {
        XCTAssertEqual((1...8).map { ChatRules.appChannelDelay(tries: $0, jitter: 0) }, [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(ChatRules.appChannelDelay(tries: 1, jitter: 1), 2.5)
        XCTAssertEqual(ChatRules.appChannelDelay(tries: 9, jitter: 1), 75)
        XCTAssertEqual(ChatRules.appChannelDelay(tries: 0, jitter: 0), 2)
    }
}

#if os(iOS)
import UIKit

/// The frame on the live bubble itself.
@MainActor
final class ChatAppFrameBubbleTests: XCTestCase {
    func testAnOffFrameRemovesTheBubble() {
        let chat = LiveChat.shared
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let bubble = ChatBubbleView(appId: "my-app", size: 56) {}
        window.addSubview(bubble)
        chat.bubble = bubble

        chat.receivedAppFrame(#"{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":false,"show_bubble":false}}"#)

        XCTAssertNil(chat.bubble)
        XCTAssertNil(bubble.superview)
        XCTAssertEqual(chat.config, .off)
    }

    func testAnOnFrameBecomesTheCurrentConfig() {
        let chat = LiveChat.shared
        chat.receivedAppFrame(#"{"kind":"live_chat","conversation_id":"*","event":"config","config":{"enabled":true,"show_bubble":true,"online":true}}"#)
        XCTAssertEqual(chat.config, ChatRules.Config(enabled: true, showBubble: true, online: true))
        // Anything else on the channel changes nothing.
        chat.receivedAppFrame("pong")
        XCTAssertEqual(chat.config, ChatRules.Config(enabled: true, showBubble: true, online: true))
    }
}
#endif
