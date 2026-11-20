import XCTest
@testable import Affiliateo

/// Affiliate codes typed inside the app (4.18.0): a coupon code without the
/// coupon. The rules are pure, so they are tested without a server; the
/// server's own half is the website's `affiliate-code/route.test.ts`.
final class AffiliateCodeTests: XCTestCase {
    private func reply(_ status: Int, _ json: String) -> AffiliateoAffiliateCode {
        AffiliateCodeRules.parseReply(status: status, data: Data(json.utf8))
    }

    // MARK: What the buyer typed

    func testKeepsACodeAsTypedMinusTheSpaceAroundItAndALeadingAt() {
        XCTAssertEqual(AffiliateCodeRules.normalize("elliotalton"), "elliotalton")
        XCTAssertEqual(AffiliateCodeRules.normalize("  ElliotAlton \n"), "ElliotAlton")
        XCTAssertEqual(AffiliateCodeRules.normalize("@elliotalton"), "elliotalton")
        XCTAssertEqual(AffiliateCodeRules.normalize("@@ elliot"), "elliot")
    }

    func testRefusesNothingASentenceAndAnythingTooLong() {
        for raw in ["", "   ", "@", "two words", "tab\there", "line\nbreak"] {
            XCTAssertNil(AffiliateCodeRules.normalize(raw), raw)
        }
        let longest = String(repeating: "a", count: AffiliateCodeRules.maxLength)
        XCTAssertEqual(AffiliateCodeRules.normalize(longest), longest)
        XCTAssertNil(AffiliateCodeRules.normalize(longest + "a"))
    }

    // MARK: What the server answered

    func testAMatchedCodeCarriesTheAffiliatesCode() {
        XCTAssertEqual(
            reply(200, #"{"ok":true,"matched":true,"ref_code":"elliotalton"}"#),
            AffiliateoAffiliateCode(matched: true, refCode: "elliotalton", reason: nil)
        )
    }

    func testACodeNobodyHasIsNotFound() {
        XCTAssertEqual(reply(200, #"{"ok":true,"matched":false}"#), .refused(.notFound))
    }

    func testTheOwnersSwitchOffTheDeviceUnknownAndABadCodeEachSayWhy() {
        XCTAssertEqual(reply(403, #"{"error":"Affiliate codes are off for this app.","code":"affiliate_codes_off"}"#), .refused(.off))
        XCTAssertEqual(reply(404, #"{"error":"Unknown device: call identify first.","code":"unknown_device"}"#), .refused(.notReady))
        XCTAssertEqual(reply(400, #"{"error":"code required","code":"invalid_code"}"#), .refused(.invalid))
    }

    func testAnythingElseIsAFailureWorthARetryNeverAMatch() {
        // An app that is not found, too many tries, a server error, a reply
        // that is not JSON, and a "matched" with no code to show for it.
        XCTAssertEqual(reply(404, #"{"error":"App not found"}"#), .refused(.failed))
        XCTAssertEqual(reply(429, #"{"error":"Too many requests"}"#), .refused(.failed))
        XCTAssertEqual(reply(500, #"{"error":"Internal server error"}"#), .refused(.failed))
        XCTAssertEqual(reply(200, "not json"), .refused(.failed))
        XCTAssertEqual(reply(200, #"{"ok":true,"matched":true}"#), .refused(.failed))
        XCTAssertEqual(reply(403, #"{"error":"Forbidden"}"#), .refused(.failed))
    }

    func testBeforeTheProviderIsUpTheAnswerIsNotReady() async {
        guard AffiliateoManager.shared == nil else { return }
        let answer = await Affiliateo.setAffiliateCode("elliotalton")
        XCTAssertEqual(answer, .refused(.notReady))
    }

    // MARK: A Mac says it is a Mac

    func testADeviceReportsItsOwnOperatingSystem() {
        let info = DeviceInfo.current(appVersion: "1.0")
        #if os(macOS)
        XCTAssertEqual(info.os, "macOS")
        XCTAssertEqual(info.deviceModel, "Mac")
        #else
        XCTAssertEqual(info.os, "iOS")
        #endif
    }
}
