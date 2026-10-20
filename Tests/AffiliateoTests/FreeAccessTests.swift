import XCTest
@testable import Affiliateo

final class EmailHashTests: XCTestCase {
    private let known = "973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b"

    func testKnownAddress() {
        XCTAssertEqual(AffiliateoEmail.sha256Hex("test@example.com"), known)
    }

    func testTrimsAndLowercasesFirst() {
        XCTAssertEqual(AffiliateoEmail.sha256Hex("  Test@Example.COM \n"), known)
    }

    func testNoAddressNoHash() {
        XCTAssertNil(AffiliateoEmail.sha256Hex(nil))
        XCTAssertNil(AffiliateoEmail.sha256Hex(""))
        XCTAssertNil(AffiliateoEmail.sha256Hex("   "))
    }
}

final class FreeAccessCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func saved(
        active: Bool = true,
        productId: String? = "pro_monthly",
        expiresAt: Date? = nil,
        checkedAt: Date
    ) -> FreeAccessCache.Entry {
        FreeAccessCache.Entry(
            AffiliateoFreeAccess(active: active, productId: productId, expiresAt: expiresAt),
            checkedAt: checkedAt
        )
    }

    func testNothingSavedIsNoAccess() {
        XCTAssertEqual(FreeAccessCache.offlineAnswer(nil, now: now), .inactive)
    }

    func testRecentAnswerWithNoEndIsKept() {
        let answer = FreeAccessCache.offlineAnswer(saved(checkedAt: now.addingTimeInterval(-day)), now: now)
        XCTAssertEqual(answer, AffiliateoFreeAccess(active: true, productId: "pro_monthly", expiresAt: nil))
    }

    func testRecentAnswerWithFutureEndIsKept() {
        let end = now.addingTimeInterval(3 * day)
        let answer = FreeAccessCache.offlineAnswer(saved(expiresAt: end, checkedAt: now.addingTimeInterval(-day)), now: now)
        XCTAssertTrue(answer.active)
        XCTAssertEqual(answer.expiresAt?.timeIntervalSince1970 ?? 0, end.timeIntervalSince1970, accuracy: 0.001)
    }

    func testPassedEndIsNoAccess() {
        let entry = saved(expiresAt: now.addingTimeInterval(-60), checkedAt: now.addingTimeInterval(-day))
        XCTAssertEqual(FreeAccessCache.offlineAnswer(entry, now: now), .inactive)
    }

    func testSevenDaysIsStillGoodButOlderIsNot() {
        XCTAssertTrue(FreeAccessCache.offlineAnswer(saved(checkedAt: now.addingTimeInterval(-7 * day)), now: now).active)
        XCTAssertFalse(FreeAccessCache.offlineAnswer(saved(checkedAt: now.addingTimeInterval(-7 * day - 1)), now: now).active)
    }

    func testAnswerFromTheFutureIsNotTrusted() {
        // A clock set back would otherwise stretch the 7 days.
        XCTAssertFalse(FreeAccessCache.offlineAnswer(saved(checkedAt: now.addingTimeInterval(day)), now: now).active)
        XCTAssertTrue(FreeAccessCache.offlineAnswer(saved(checkedAt: now.addingTimeInterval(60)), now: now).active)
    }

    func testSavedNoIsNo() {
        XCTAssertEqual(FreeAccessCache.offlineAnswer(saved(active: false, checkedAt: now), now: now), .inactive)
    }

    func testSaveLoadAndClear() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "affiliateo-tests-\(UUID().uuidString)"))
        let entry = saved(expiresAt: now.addingTimeInterval(day), checkedAt: now)
        FreeAccessCache.save(entry, defaults)
        XCTAssertEqual(FreeAccessCache.load(defaults), entry)
        FreeAccessCache.clear(defaults)
        XCTAssertNil(FreeAccessCache.load(defaults))
    }
}

final class FreeAccessReplyTests: XCTestCase {
    private func parse(_ json: String) -> AffiliateoFreeAccess? {
        FreeAccessCache.parseReply(Data(json.utf8))
    }

    func testActiveWithPlanAndEnd() {
        let answer = parse(#"{"active":true,"product_id":"pro_yearly","expires_at":"2026-11-17T12:00:00.000Z"}"#)
        XCTAssertEqual(answer?.active, true)
        XCTAssertEqual(answer?.productId, "pro_yearly")
        XCTAssertEqual(answer?.expiresAt?.timeIntervalSince1970, 1_794_916_800)
    }

    func testFullAccessWithNoEnd() {
        let answer = parse(#"{"active":true,"product_id":null,"expires_at":null}"#)
        XCTAssertEqual(answer, AffiliateoFreeAccess(active: true, productId: nil, expiresAt: nil))
    }

    func testInactive() {
        XCTAssertEqual(parse(#"{"active":false,"product_id":null,"expires_at":null}"#), .inactive)
    }

    func testOtherDateShapes() {
        XCTAssertEqual(FreeAccessCache.parseDate("2026-11-17T12:00:00Z")?.timeIntervalSince1970, 1_794_916_800)
        XCTAssertEqual(FreeAccessCache.parseDate("2026-11-17T13:00:00+01:00")?.timeIntervalSince1970, 1_794_916_800)
        XCTAssertEqual(FreeAccessCache.parseDate("2026-11-17T12:00:00.123456+00:00")?.timeIntervalSince1970 ?? 0, 1_794_916_800.123, accuracy: 0.001)
    }

    func testNotAReply() {
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"{"error":"rate limited"}"#))
        // An end that cannot be read must not become "no end".
        XCTAssertNil(parse(#"{"active":true,"expires_at":"next tuesday"}"#))
    }
}

/// The store prices a US phone reports (4.13.0): whole cents, once a day.
final class StorePricesTests: XCTestCase {
    func testWholeCents() {
        XCTAssertEqual(AffiliateoStorePrices.cents(Decimal(string: "6.99")!), 699)
        XCTAssertEqual(AffiliateoStorePrices.cents(Decimal(string: "59.99")!), 5999)
        XCTAssertEqual(AffiliateoStorePrices.cents(Decimal(string: "0.995")!), 100)
        XCTAssertNil(AffiliateoStorePrices.cents(0))
    }

    func testOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AffiliateoStorePrices.isDue(lastChecked: nil, now: now))
        XCTAssertFalse(AffiliateoStorePrices.isDue(lastChecked: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(AffiliateoStorePrices.isDue(lastChecked: now.addingTimeInterval(-25 * 3_600), now: now))
        // A clock set back does not lock the check out.
        XCTAssertTrue(AffiliateoStorePrices.isDue(lastChecked: now.addingTimeInterval(3_600), now: now))
    }
}
