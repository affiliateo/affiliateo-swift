import XCTest
@testable import Affiliateo

/// 4.16.2: what the event queue does with each answer and how long it waits
/// before its next try (SendRetry.swift).
final class SendRetryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testOutcomes() {
        XCTAssertEqual(SendRetry.outcome(status: nil), .kept)
        for status in [200, 201, 202, 204, 299] {
            XCTAssertEqual(SendRetry.outcome(status: status), .sent, "\(status)")
        }
        for status in [400, 401, 403, 405, 409, 410, 413, 415, 422, 451, 499] {
            XCTAssertEqual(SendRetry.outcome(status: status), .refused, "\(status)")
        }
        // 404 is the server's "Call /identify first" for a device it does not
        // know yet, which a later try fixes.
        for status in [404, 408, 429, 500, 502, 503, 504, 599, 301, 304] {
            XCTAssertEqual(SendRetry.outcome(status: status), .kept, "\(status)")
        }
    }

    func testWaitDoublesUpToFiveMinutes() {
        let waits = (1...10).map { SendRetry.wait(failures: $0, status: 500, retryAfter: nil, now: t0, jitter: 0) }
        XCTAssertEqual(waits, [5, 10, 20, 40, 80, 160, 300, 300, 300, 300])
        XCTAssertEqual(SendRetry.wait(failures: 0, status: nil, retryAfter: nil, now: t0, jitter: 0), 5)
        XCTAssertEqual(SendRetry.wait(failures: 1_000, status: nil, retryAfter: nil, now: t0, jitter: 0), 300)
    }

    func testJitterAddsUpToAQuarter() {
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 500, retryAfter: nil, now: t0, jitter: 1), 6.25)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 500, retryAfter: nil, now: t0, jitter: 0.5), 5.625)
        XCTAssertEqual(SendRetry.wait(failures: 7, status: 500, retryAfter: nil, now: t0, jitter: 1), 375)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 500, retryAfter: nil, now: t0, jitter: 9), 6.25)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 500, retryAfter: nil, now: t0, jitter: -1), 5)
    }

    func testRetryAfterCountsFor429And503Only() {
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 429, retryAfter: "120", now: t0, jitter: 0), 120)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 503, retryAfter: "120", now: t0, jitter: 0), 120)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 500, retryAfter: "120", now: t0, jitter: 0), 5)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 408, retryAfter: "120", now: t0, jitter: 0), 5)
        // Never shorter than the backoff, and at most an hour.
        XCTAssertEqual(SendRetry.wait(failures: 3, status: 429, retryAfter: "2", now: t0, jitter: 0), 20)
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 429, retryAfter: "86400", now: t0, jitter: 0), 3_600)
        // The jitter goes on top of what was asked.
        XCTAssertEqual(SendRetry.wait(failures: 1, status: 429, retryAfter: "60", now: t0, jitter: 1), 75)
        // Unreadable: the backoff alone.
        XCTAssertEqual(SendRetry.wait(failures: 2, status: 503, retryAfter: "soon", now: t0, jitter: 0), 10)
    }

    func testRetryAfterReadsSecondsAndDates() {
        XCTAssertEqual(SendRetry.retryAfterSeconds("30", now: t0), 30)
        XCTAssertEqual(SendRetry.retryAfterSeconds(" 30 ", now: t0), 30)
        XCTAssertEqual(SendRetry.retryAfterSeconds("0", now: t0), 0)
        XCTAssertEqual(SendRetry.retryAfterSeconds("99999", now: t0), 3_600)
        // Wed, 21 Oct 2015 07:28:00 GMT is 1445412480.
        let date = "Wed, 21 Oct 2015 07:28:00 GMT"
        XCTAssertEqual(SendRetry.retryAfterSeconds(date, now: Date(timeIntervalSince1970: 1_445_412_480 - 90)), 90)
        XCTAssertEqual(SendRetry.retryAfterSeconds(date, now: Date(timeIntervalSince1970: 1_445_412_480 + 90)), 0)
        XCTAssertEqual(SendRetry.retryAfterSeconds(date, now: Date(timeIntervalSince1970: 1_445_412_480 - 7_200)), 3_600)
        for unreadable in [nil, "", "  ", "soon", "-5", "1.5", "30s", "+30", "Wed, 21 Oct 2015"] {
            XCTAssertNil(SendRetry.retryAfterSeconds(unreadable, now: t0), String(describing: unreadable))
        }
    }

    func testWaitsAfterAKeptAnswerAndResetsOnTheNextOther() {
        var retry = SendRetry()
        XCTAssertTrue(retry.canSend(at: t0))

        XCTAssertEqual(retry.answered(status: 503, retryAfter: nil, at: t0, jitter: 0), .kept)
        XCTAssertEqual(retry.failures, 1)
        XCTAssertFalse(retry.canSend(at: t0.addingTimeInterval(4.9)))
        XCTAssertTrue(retry.canSend(at: t0.addingTimeInterval(5)))

        let t1 = t0.addingTimeInterval(5)
        XCTAssertEqual(retry.answered(status: 500, retryAfter: nil, at: t1, jitter: 0), .kept)
        XCTAssertEqual(retry.failures, 2)
        XCTAssertFalse(retry.canSend(at: t1.addingTimeInterval(9.9)))
        XCTAssertTrue(retry.canSend(at: t1.addingTimeInterval(10)))

        XCTAssertEqual(retry.answered(status: 200, retryAfter: nil, at: t1, jitter: 0), .sent)
        XCTAssertEqual(retry.failures, 0)
        XCTAssertTrue(retry.canSend(at: t1))

        _ = retry.answered(status: 503, retryAfter: nil, at: t1, jitter: 0)
        XCTAssertEqual(retry.answered(status: 400, retryAfter: nil, at: t1, jitter: 0), .refused)
        XCTAssertEqual(retry.failures, 0)
        XCTAssertTrue(retry.canSend(at: t1))
    }

    func testNetworkBackEndsOnlyAWaitForTheNetwork() {
        var retry = SendRetry()
        _ = retry.answered(status: nil, retryAfter: nil, at: t0, jitter: 0)
        _ = retry.answered(status: nil, retryAfter: nil, at: t0, jitter: 0)
        XCTAssertFalse(retry.canSend(at: t0))
        retry.networkBack()
        XCTAssertTrue(retry.canSend(at: t0))
        XCTAssertEqual(retry.failures, 0)

        // The server answered "busy, come back in a minute": that holds.
        _ = retry.answered(status: 429, retryAfter: "60", at: t0, jitter: 0)
        retry.networkBack()
        XCTAssertFalse(retry.canSend(at: t0.addingTimeInterval(59)))
        XCTAssertTrue(retry.canSend(at: t0.addingTimeInterval(60)))
    }
}
