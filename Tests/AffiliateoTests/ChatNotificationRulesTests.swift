import XCTest
@testable import Affiliateo

/// 4.17.0: the bubble's wiggle, a reply as a notification, the push token
/// and the greeting's notification. The rules only; the screens are in
/// Chat.swift.
final class ChatNotificationRulesTests: XCTestCase {
    private func env(optedOut: Bool = false, deviceId: String? = "ios-ABC", userId: String? = "user-1") -> ChatRules.Env {
        ChatRules.Env(
            appId: "my-app",
            apiUrl: "https://affiliateo.com/",
            deviceId: deviceId,
            visitorId: "v_123",
            userId: userId,
            optedOut: optedOut,
            debug: false
        )
    }

    private func config(_ json: String) -> ChatRules.Config {
        ChatRules.parseConfig(Data(json.utf8))
    }

    private let on = ChatRules.Config(enabled: true, showBubble: true, online: false)

    // MARK: The wiggle

    func testTheConfigCarriesTheWiggle() {
        XCTAssertEqual(config(#"{"enabled":true,"bubble":{"wiggle_seconds":30}}"#).bubble.wiggleSeconds, 30)
        XCTAssertEqual(config(#"{"enabled":true,"bubble":{"wiggle_seconds":10}}"#).bubble.wiggleSeconds, 10)
        // Off in the dashboard.
        XCTAssertEqual(config(#"{"enabled":true,"bubble":{"wiggle_seconds":0}}"#).bubble.wiggleSeconds, 0)
    }

    /// A server from before the wiggle sends no field: the bubble stays still.
    func testAConfigWithoutTheFieldDoesNotWiggle() {
        XCTAssertEqual(config(#"{"enabled":true,"bubble":{"position":"bottom-left"}}"#).bubble.wiggleSeconds, 0)
        XCTAssertEqual(config(#"{"enabled":true}"#).bubble.wiggleSeconds, 0)
        XCTAssertEqual(ChatRules.Bubble.standard.wiggleSeconds, 0)
    }

    func testAnOddWiggleIsOffOrKeptInBounds() {
        XCTAssertEqual(ChatRules.wiggleSeconds("30"), 0)
        XCTAssertEqual(ChatRules.wiggleSeconds(nil), 0)
        XCTAssertEqual(ChatRules.wiggleSeconds(-5), 0)
        XCTAssertEqual(config(#"{"enabled":true,"bubble":{"wiggle_seconds":true}}"#).bubble.wiggleSeconds, 0)
        XCTAssertEqual(config(#"{"enabled":true,"bubble":{"wiggle_seconds":null}}"#).bubble.wiggleSeconds, 0)
        XCTAssertEqual(ChatRules.wiggleSeconds(Double.nan), 0)
        // Never faster than every 3 seconds, never slower than once an hour.
        XCTAssertEqual(ChatRules.wiggleSeconds(1), 3)
        XCTAssertEqual(ChatRules.wiggleSeconds(0.5), 3)
        XCTAssertEqual(ChatRules.wiggleSeconds(20.9), 20)
        XCTAssertEqual(ChatRules.wiggleSeconds(999_999), 3600)
    }

    /// setChatBubbleWiggle(seconds:): any whole number, 3 at least; 0 or nil is off.
    func testTheAppsOwnWiggle() {
        XCTAssertEqual(ChatRules.wiggleOverride(nil), 0)
        XCTAssertEqual(ChatRules.wiggleOverride(0), 0)
        XCTAssertEqual(ChatRules.wiggleOverride(-10), 0)
        XCTAssertEqual(ChatRules.wiggleOverride(1), 3)
        XCTAssertEqual(ChatRules.wiggleOverride(3), 3)
        XCTAssertEqual(ChatRules.wiggleOverride(45), 45)
        XCTAssertEqual(ChatRules.wiggleOverride(7), 7)
    }

    func testTheAppsOwnWiggleWinsOverTheDashboards() {
        let thirty = config(#"{"enabled":true,"bubble":{"wiggle_seconds":30}}"#)
        // No call from the app: the dashboard's.
        XCTAssertEqual(ChatRules.wiggleEvery(override: nil, config: thirty), 30)
        XCTAssertEqual(ChatRules.wiggleEvery(override: nil, config: on), 0)
        XCTAssertEqual(ChatRules.wiggleEvery(override: nil, config: nil), 0)
        // The app's own seconds, and its "off".
        XCTAssertEqual(ChatRules.wiggleEvery(override: 8, config: thirty), 8)
        XCTAssertEqual(ChatRules.wiggleEvery(override: 0, config: thirty), 0)
        XCTAssertEqual(ChatRules.wiggleEvery(override: 12, config: nil), 12)
    }

    func testItWigglesOnlyWhenNothingSpeaksAgainstIt() {
        func wiggles(every: Int = 30, shown: Bool = true, open: Bool = false, front: Bool = true, dragging: Bool = false, reduce: Bool = false) -> Bool {
            ChatRules.wigglesNow(every: every, bubbleShown: shown, chatOpen: open, inFront: front, dragging: dragging, reduceMotion: reduce)
        }
        XCTAssertTrue(wiggles())
        XCTAssertFalse(wiggles(every: 0))
        XCTAssertFalse(wiggles(shown: false))
        XCTAssertFalse(wiggles(open: true))
        XCTAssertFalse(wiggles(front: false))
        XCTAssertFalse(wiggles(dragging: true))
        // Never with Reduce Motion.
        XCTAssertFalse(wiggles(reduce: true))
    }

    /// About 0.6 s: a few small left and right turns of 10 to 12 degrees
    /// that die down, starting and ending at rest.
    func testOneWiggleIsShortSmallAndDiesDown() {
        let turns = ChatRules.wiggleDegrees
        // The website's bubble and the other SDKs turn the same way.
        XCTAssertEqual(turns, [0, -12, 10, -8, 6, -3, 0])
        XCTAssertEqual(ChatRules.wiggleDuration, 0.6, accuracy: 0.001)
        XCTAssertEqual(turns.first, 0)
        XCTAssertEqual(turns.last, 0)
        let swings = turns.dropFirst().dropLast()
        XCTAssertGreaterThanOrEqual(swings.count, 3)
        let largest = swings.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(largest, 10)
        XCTAssertLessThanOrEqual(largest, 12)
        for (a, b) in zip(swings, swings.dropFirst()) {
            XCTAssertLessThan(a * b, 0, "left, then right")
            XCTAssertLessThan(abs(b), abs(a), "each turn smaller than the last")
        }
    }

    // MARK: A reply as a notification

    /// The server's push, as the wire contract has it.
    private let push: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Copydraw", "body": "Hi there"], "sound": "default", "thread-id": "affiliateo-chat"],
        "affiliateo_chat": ["app": "my-app", "conversation_id": "c-1", "message_id": "m-9"],
    ]

    func testAChatPushIsRecognized() {
        XCTAssertEqual(ChatRules.notice(push), ChatRules.Notice(app: "my-app", conversationId: "c-1", messageId: "m-9"))
        // Ids sent as numbers read the same.
        XCTAssertEqual(ChatRules.notice(["affiliateo_chat": ["conversation_id": 12, "message_id": 345]])?.messageId, "345")
        XCTAssertEqual(ChatRules.noticeThread, "affiliateo-chat")
    }

    func testTheAppsOwnNotificationsAreNotTheChats() {
        XCTAssertNil(ChatRules.notice([:]))
        XCTAssertNil(ChatRules.notice(["aps": ["alert": "Today's page is ready"]]))
        XCTAssertNil(ChatRules.notice(["route": "bible_guide"]))
        // Android's flat marker is not an iPhone push.
        XCTAssertNil(ChatRules.notice(["affiliateo_chat": "1"]))
    }

    func testItShowsAsABannerUnlessTheChatIsOpen() {
        XCTAssertEqual(ChatRules.noticeShow(push, chatOpen: false), .banner)
        XCTAssertEqual(ChatRules.noticeShow(push, chatOpen: true), .quiet)
        XCTAssertEqual(ChatRules.noticeShow(["aps": ["alert": "Keep your streak going"]], chatOpen: false), .notOurs)
        XCTAssertEqual(ChatRules.noticeShow(["aps": ["alert": "Keep your streak going"]], chatOpen: true), .notOurs)
    }

    func testTheSdksOwnNotificationLooksLikeThePush() {
        let message = ChatRules.Notice(app: "my-app", conversationId: "c-1", messageId: "m-9")
        XCTAssertEqual(ChatRules.notice(ChatRules.noticeInfo(message)), message)
        let greeting = ChatRules.Notice(app: "my-app", greetingId: "g1")
        XCTAssertEqual(ChatRules.notice(ChatRules.noticeInfo(greeting)), greeting)
        XCTAssertEqual(ChatRules.noticeShow(ChatRules.noticeInfo(greeting), chatOpen: false), .banner)
    }

    func testTheLineIsTheMessageCutToAbout180Characters() {
        XCTAssertEqual(ChatRules.noticeBody("  Hi there\n", language: "en"), "Hi there")
        let long = String(repeating: "word ", count: 100)
        let cut = ChatRules.noticeBody(long, language: "en")
        XCTAssertLessThanOrEqual(cut.count, 180)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(cut.dropLast())))
        XCTAssertEqual(ChatRules.noticeBody(String(repeating: "a", count: 180), language: "en").count, 180)
    }

    func testAMessageWithNoTextSaysSoInThePersonsLanguage() {
        XCTAssertEqual(ChatRules.noticeBody("", language: "en-US"), "Sent you a message")
        XCTAssertEqual(ChatRules.noticeBody(nil, language: "es-MX"), "Te envió un mensaje")
        XCTAssertEqual(ChatRules.noticeBody("   ", language: "de"), "Hat dir eine Nachricht gesendet")
        XCTAssertEqual(ChatRules.noticeBody(nil, language: "sv"), "Sent you a message")
        for (language, words) in ChatRules.ChatWords.all {
            XCTAssertFalse(words.sentMessage.isEmpty, language)
        }
    }

    func testATeamMessageOnTheSocket() {
        let frame: [String: Any] = [
            "kind": "live_chat", "conversation_id": "c-1", "event": "message",
            "message": ["id": "m-9", "sender": "team", "body": "Hi there", "created_at": "2026-11-11T12:00:00Z"],
        ]
        XCTAssertEqual(ChatRules.teamMessage(frame), ChatRules.TeamMessage(id: "m-9", conversationId: "c-1", body: "Hi there"))
        // The person's own message, a system line, a read receipt: not one.
        var own = frame
        own["message"] = ["id": "m-10", "sender": "visitor", "body": "Hello"]
        XCTAssertNil(ChatRules.teamMessage(own))
        var system = frame
        system["message"] = ["id": "m-11", "sender": "system", "body": "closed"]
        XCTAssertNil(ChatRules.teamMessage(system))
        XCTAssertNil(ChatRules.teamMessage(["kind": "live_chat", "event": "read", "by": "visitor"]))
        XCTAssertNil(ChatRules.teamMessage(["kind": "other", "event": "message", "message": ["sender": "team"]]))
    }

    /// The SDK posts its own notification only in front, with the chat
    /// closed, on a phone without a registered push token.
    func testTheLocalNotificationIsTheFallback() {
        XCTAssertTrue(ChatRules.postsLocalNotice(inFront: true, chatOpen: false, pushRegistered: false))
        // A registered phone gets the push itself.
        XCTAssertFalse(ChatRules.postsLocalNotice(inFront: true, chatOpen: false, pushRegistered: true))
        XCTAssertFalse(ChatRules.postsLocalNotice(inFront: true, chatOpen: true, pushRegistered: false))
        XCTAssertFalse(ChatRules.postsLocalNotice(inFront: false, chatOpen: false, pushRegistered: false))
    }

    func testTheChatOnScreenFlag() {
        ChatOnScreen.set(true)
        XCTAssertTrue(ChatOnScreen.isOpen)
        ChatOnScreen.set(false)
        XCTAssertFalse(ChatOnScreen.isOpen)
    }

    // MARK: The greeting

    private let greeted = #"{"enabled":true,"show_bubble":true,"app":{"id":"a1","name":"Copydraw"},"greeting":" Hi! How can we help? ","bubble":{"greeting_id":"g1"}}"#

    func testTheConfigCarriesTheAppsNameAndTheGreeting() {
        let c = config(greeted)
        XCTAssertEqual(c.appName, "Copydraw")
        XCTAssertEqual(c.greeting, "Hi! How can we help?")
        XCTAssertEqual(c.bubble.greetingId, "g1")
        let bare = config(#"{"enabled":true,"greeting":null,"app":{"name":""}}"#)
        XCTAssertNil(bare.appName)
        XCTAssertNil(bare.greeting)
    }

    func testTheGreetingInThePersonsLanguage() {
        let c = config(#"{"enabled":true,"greeting":"Hi!","greetings":{"es":"¡Hola!","pt":""},"bubble":{"greeting_id":"g1"}}"#)
        XCTAssertEqual(ChatRules.greetingText(c, language: "es-MX"), "¡Hola!")
        // No version in their language: the main text.
        XCTAssertEqual(ChatRules.greetingText(c, language: "fr-FR"), "Hi!")
        XCTAssertEqual(ChatRules.greetingText(c, language: "pt-BR"), "Hi!")
        XCTAssertNil(ChatRules.greetingText(on, language: "en"))
    }

    func testTheGreetingGoesOutOncePerGreeting() {
        let c = config(greeted)
        func due(allowed: Bool = true, config: ChatRules.Config? = c, pending: Bool = true, notified: String? = nil, open: Bool = false) -> Bool {
            ChatRules.greetingNoticeDue(allowed: allowed, config: config, pending: pending, notifiedId: notified, chatOpen: open, language: "en")
        }
        XCTAssertTrue(due())
        // Not before the app says notifications are allowed.
        XCTAssertFalse(due(allowed: false))
        // Seen already, or the person has a thread: the red 1 is gone too.
        XCTAssertFalse(due(pending: false))
        // Never twice for the same greeting; a new greeting goes out again.
        XCTAssertFalse(due(notified: "g1"))
        XCTAssertTrue(due(notified: "g0"))
        XCTAssertFalse(due(open: true))
        // The config is not here yet, the chat is off, or there is no greeting.
        XCTAssertFalse(due(config: nil))
        XCTAssertFalse(due(config: .off))
        XCTAssertFalse(due(config: on))
        XCTAssertFalse(due(config: config(#"{"enabled":true,"bubble":{"greeting_id":"g1"}}"#)))
        XCTAssertFalse(due(config: config(#"{"enabled":true,"greeting":"Hi!","bubble":{}}"#)))
    }

    // MARK: The push token

    func testAppleTokenAsHex() {
        XCTAssertEqual(ChatRules.pushToken(Data([0x00, 0x0f, 0xa1, 0xff])), "000fa1ff")
        XCTAssertEqual(ChatRules.pushToken(Data()), "")
        XCTAssertEqual(ChatRules.pushToken(Data(repeating: 0xab, count: 32)).count, 64)
    }

    private func device(token: String = "abc123", language: String = "en-US", userId: String? = "user-1") -> ChatRules.PushDevice {
        ChatRules.PushDevice(app: "my-app", token: token, bundleId: "com.example.app", environment: "production", deviceId: "ios-ABC", userId: userId, language: language)
    }

    /// POST /api/live-chat/push-devices, as the wire contract has it.
    func testTheRegistrationBody() {
        let body = ChatRules.pushDeviceBody(device(), visitorId: "v_123")
        XCTAssertEqual(body["app"] as? String, "my-app")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["token"] as? String, "abc123")
        XCTAssertEqual(body["bundle_id"] as? String, "com.example.app")
        XCTAssertEqual(body["environment"] as? String, "production")
        XCTAssertEqual(body["device_id"] as? String, "ios-ABC")
        XCTAssertEqual(body["visitor_id"] as? String, "v_123")
        XCTAssertEqual(body["user_id"] as? String, "user-1")
        XCTAssertEqual(body["language"] as? String, "en-US")
        XCTAssertEqual(body.count, 9)
        // The optional ids are left out when there are none.
        let bare = ChatRules.pushDeviceBody(device(userId: nil), visitorId: nil)
        XCTAssertNil(bare["visitor_id"])
        XCTAssertNil(bare["user_id"])
        XCTAssertEqual(bare.count, 7)
        XCTAssertEqual(ChatRules.pushDevicesURL(apiUrl: "https://affiliateo.com/")?.absoluteString, "https://affiliateo.com/api/live-chat/push-devices")
    }

    func testWhatIsRegistered() {
        let d = ChatRules.pushDevice(env: env(), config: on, token: "abc123", bundleId: "com.example.app", environment: "sandbox", language: "pt-BR")
        XCTAssertEqual(d, ChatRules.PushDevice(app: "my-app", token: "abc123", bundleId: "com.example.app", environment: "sandbox", deviceId: "ios-ABC", userId: "user-1", language: "pt-BR"))
        // The same device id the chat page sends.
        XCTAssertEqual(d?.deviceId, env().deviceId)
    }

    func testNothingIsRegisteredWithoutATokenTheChatOnOrADeviceId() {
        func registers(env e: ChatRules.Env? = nil, config: ChatRules.Config? = nil, token: String? = "abc123", bundleId: String? = "com.example.app") -> Bool {
            ChatRules.pushDevice(env: e ?? env(), config: config ?? on, token: token, bundleId: bundleId, environment: "production", language: "en") != nil
        }
        XCTAssertTrue(registers())
        XCTAssertFalse(registers(token: nil))
        XCTAssertFalse(registers(token: ""))
        XCTAssertFalse(registers(config: .off))
        XCTAssertFalse(ChatRules.pushDevice(env: env(), config: nil, token: "abc123", bundleId: "com.example.app", environment: "production", language: "en") != nil)
        // Opted out: the chat carries no device id, so no reply could find the phone.
        XCTAssertFalse(registers(env: env(optedOut: true)))
        XCTAssertFalse(registers(env: env(deviceId: nil)))
        XCTAssertFalse(registers(bundleId: nil))
    }

    func testItRegistersOnceALaunchAndWhenTheTokenTheAppOrTheLanguageChanges() {
        let sent = device()
        // Nothing answered yet in this launch.
        XCTAssertTrue(ChatRules.pushRegistrationDue(answered: nil, next: sent))
        // Answered in this launch: nothing more to send.
        XCTAssertFalse(ChatRules.pushRegistrationDue(answered: sent, next: sent))
        XCTAssertTrue(ChatRules.pushRegistrationDue(answered: sent, next: device(token: "def456")))
        XCTAssertTrue(ChatRules.pushRegistrationDue(answered: sent, next: device(language: "es-ES")))
        var otherApp = sent
        otherApp.app = "another-app"
        XCTAssertTrue(ChatRules.pushRegistrationDue(answered: sent, next: otherApp))
        XCTAssertTrue(ChatRules.pushRegistrationDue(answered: sent, next: device(userId: "user-2")))
    }

    func testTheServersAnswer() {
        XCTAssertEqual(ChatRules.pushAnswer(status: 200, body: Data(#"{"ok":true}"#.utf8)), .ok)
        // An app it does not know, or one whose chat is off: never an error.
        XCTAssertEqual(ChatRules.pushAnswer(status: 200, body: Data(#"{"ok":false,"reason":"chat_off"}"#.utf8)), .notTaken)
        XCTAssertEqual(ChatRules.pushAnswer(status: 200, body: Data("<html>".utf8)), .notTaken)
        // Too many requests, a server error, a server from before the route: the next launch.
        XCTAssertEqual(ChatRules.pushAnswer(status: 429, body: Data(#"{"error":"Too many requests"}"#.utf8)), .failed)
        XCTAssertEqual(ChatRules.pushAnswer(status: 500, body: Data(#"{"ok":false}"#.utf8)), .failed)
        XCTAssertEqual(ChatRules.pushAnswer(status: 404, body: nil), .failed)
        // Offline: tried again later.
        XCTAssertEqual(ChatRules.pushAnswer(status: nil, body: nil), .noAnswer)
        XCTAssertTrue(ChatRules.parseOk(Data(#"{"ok":true}"#.utf8)))
        XCTAssertFalse(ChatRules.parseOk(Data(#"{"ok":"true"}"#.utf8)))
    }

    /// A provisioning profile as it sits in an app: a signed envelope
    /// (bytes) around a property list.
    private func profile(apsEnvironment: String?) -> Data {
        let entitlement = apsEnvironment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlement)<key>get-task-allow</key><true/></dict><key>Name</key><string>Test</string></dict></plist>
        """
        return Data([0x30, 0x82, 0x1f, 0x00, 0xff]) + Data(plist.utf8) + Data([0x00, 0xa0, 0x82, 0xfe])
    }

    func testApplesPushServiceForTheBuild() {
        // The Simulator is always the sandbox.
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: nil, simulator: true, debugBuild: false), "sandbox")
        // A build run from Xcode on a phone: a development profile.
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: profile(apsEnvironment: "development"), simulator: false, debugBuild: true), "sandbox")
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: profile(apsEnvironment: "development"), simulator: false, debugBuild: false), "sandbox")
        // An ad hoc build: a distribution profile.
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: profile(apsEnvironment: "production"), simulator: false, debugBuild: false), "production")
        // The App Store and TestFlight: no profile in the app.
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: nil, simulator: false, debugBuild: false), "production")
        // A profile without the entitlement, or one that cannot be read: the build's configuration.
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: profile(apsEnvironment: nil), simulator: false, debugBuild: true), "sandbox")
        XCTAssertEqual(ChatRules.apnsEnvironment(profile: Data("junk".utf8), simulator: false, debugBuild: false), "production")
        XCTAssertEqual(ChatRules.apsEnvironment(inProfile: profile(apsEnvironment: "production")), "production")
        XCTAssertNil(ChatRules.apsEnvironment(inProfile: Data()))
    }

    func testTheKeysOnThePhone() {
        XCTAssertEqual(ChatRules.greetingNotifiedKey("my-app"), "affiliateo_chat_greeting_notified_my-app")
        XCTAssertEqual(ChatRules.pushKey("my-app"), "affiliateo_chat_push_my-app")
        XCTAssertEqual(ChatRules.pushForgetKey("my-app"), "affiliateo_chat_push_forget_my-app")
        XCTAssertEqual(ChatRules.pushHeldKey("my-app"), "affiliateo_chat_push_held_my-app")
    }
}
