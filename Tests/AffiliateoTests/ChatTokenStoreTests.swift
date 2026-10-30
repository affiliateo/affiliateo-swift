import XCTest
@testable import Affiliateo

/// 4.15.4 (review S18): the thread key lives in the Keychain, not in
/// UserDefaults (which backups copy). An older version's key moves over once;
/// a key a deleted install left in the Keychain is never used.
final class ChatTokenStoreTests: XCTestCase {
    private let token = "lct_" + String(repeating: "A", count: 42) + "_"
    private let other = "lct_" + String(repeating: "B", count: 42) + "_"
    private var suite = ""
    private var defaults: UserDefaults!
    private var secrets: MemorySecrets!
    private var store: ChatTokenStore { ChatTokenStore(secrets: secrets, defaults: defaults) }

    override func setUp() {
        super.setUp()
        suite = "affiliateo-chat-token-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        secrets = MemorySecrets()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNothingSavedIsNoKey() {
        XCTAssertNil(store.token(appId: "app"))
    }

    func testASavedKeyComesBackFromTheKeychainOnly() {
        XCTAssertTrue(store.save(token, appId: "app"))
        XCTAssertEqual(store.token(appId: "app"), token)
        XCTAssertEqual(secrets.items["app"], token)
        XCTAssertNil(defaults.string(forKey: ChatRules.tokenKey("app")))
        // Another app's thread is its own.
        XCTAssertNil(store.token(appId: "other-app"))
    }

    func testAnOlderVersionsKeyMovesOverOnce() {
        defaults.set(token, forKey: ChatRules.tokenKey("app"))
        XCTAssertEqual(store.token(appId: "app"), token)
        XCTAssertNil(defaults.string(forKey: ChatRules.tokenKey("app")))
        XCTAssertEqual(secrets.items["app"], token)
        XCTAssertEqual(store.token(appId: "app"), token)
    }

    func testAnOlderKeyStaysWhereItWasWhileTheKeychainSaysNo() {
        secrets.refuses = true
        defaults.set(token, forKey: ChatRules.tokenKey("app"))
        XCTAssertEqual(store.token(appId: "app"), token)
        XCTAssertEqual(defaults.string(forKey: ChatRules.tokenKey("app")), token)
        secrets.refuses = false
        XCTAssertEqual(store.token(appId: "app"), token)
        XCTAssertNil(defaults.string(forKey: ChatRules.tokenKey("app")))
    }

    func testAnOlderValueThatIsNoKeyIsDropped() {
        defaults.set("lct_bad", forKey: ChatRules.tokenKey("app"))
        XCTAssertNil(store.token(appId: "app"))
        XCTAssertNil(defaults.string(forKey: ChatRules.tokenKey("app")))
        XCTAssertTrue(secrets.items.isEmpty)
    }

    func testAKeyADeletedInstallLeftIsRemovedNotUsed() {
        // The Keychain outlives the app; UserDefaults (and its note) does not.
        secrets.items["app"] = token
        XCTAssertNil(store.token(appId: "app"))
        XCTAssertNil(secrets.items["app"])
    }

    func testOnlyKeysAreSaved() {
        XCTAssertFalse(store.save("lct_bad", appId: "app"))
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertNil(store.token(appId: "app"))
    }

    func testANewKeyReplacesTheOld() {
        store.save(token, appId: "app")
        store.save(other, appId: "app")
        XCTAssertEqual(store.token(appId: "app"), other)
    }

    func testANewKeyLeavesNoOlderCopyBehind() {
        // The move failed once (the Keychain said no), so the older key is
        // still in UserDefaults when the page hands over a new one.
        secrets.refuses = true
        defaults.set(token, forKey: ChatRules.tokenKey("app"))
        XCTAssertEqual(store.token(appId: "app"), token)
        secrets.refuses = false
        XCTAssertTrue(store.save(other, appId: "app"))
        XCTAssertNil(defaults.string(forKey: ChatRules.tokenKey("app")))
        XCTAssertEqual(store.token(appId: "app"), other)
    }

    func testSigningOutRemovesItEverywhere() {
        store.save(token, appId: "app")
        defaults.set(other, forKey: ChatRules.tokenKey("app"))
        store.clear(appId: "app")
        XCTAssertNil(store.token(appId: "app"))
        XCTAssertNil(secrets.items["app"])
        XCTAssertNil(defaults.string(forKey: ChatRules.tokenKey("app")))
        XCTAssertFalse(defaults.bool(forKey: ChatTokenStore.savedKey("app")))
    }

    #if os(iOS)
    /// The real Keychain, where the test runner may use it.
    func testTheKeychainKeepsAndForgetsIt() throws {
        let keychain = KeychainChatSecrets()
        let account = "test-\(UUID().uuidString)"
        guard keychain.write(token, account: account) else {
            throw XCTSkip("no Keychain for this test runner")
        }
        XCTAssertEqual(keychain.read(account: account), token)
        XCTAssertTrue(keychain.write(other, account: account))
        XCTAssertEqual(keychain.read(account: account), other)
        keychain.delete(account: account)
        XCTAssertNil(keychain.read(account: account))
    }
    #endif
}

private final class MemorySecrets: ChatSecrets {
    var items: [String: String] = [:]
    var refuses = false

    func read(account: String) -> String? { items[account] }

    func write(_ value: String, account: String) -> Bool {
        guard !refuses else { return false }
        items[account] = value
        return true
    }

    func delete(account: String) { items[account] = nil }
}
