import XCTest
@testable import Affiliateo

/// 4.16.2: what a flush does with each answer. Events the server did not take
/// for a reason that may change wait (5 s doubling up to 5 minutes, at least
/// the Retry-After of a 429 or 503) instead of being dropped after their
/// third try; a refusal drops them with one debug line.
final class EventQueueRetryTests: XCTestCase {
    private let eventUrl = "https://affiliateo.com/api/v1/mobile/event"
    private let purchaseUrl = "https://affiliateo.com/api/v1/mobile/purchase"
    private var suite = ""
    private var defaults: UserDefaults!
    private var clock: TestClock!
    private var server: AnswerServer!
    private var logged: LogLines!

    override func setUp() {
        super.setUp()
        suite = "affiliateo-event-retry-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        clock = TestClock()
        server = AnswerServer()
        logged = LogLines()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// No jitter, so the waits are exactly 5 s, 10 s, 20 s...
    private func makeQueue(maxQueueSize: Int = 100) -> EventQueue {
        let clock = self.clock!, logged = self.logged!
        return EventQueue(
            userDefaults: defaults,
            maxQueueSize: maxQueueSize,
            autoFlush: false,
            now: { clock.now },
            jitter: { 0 },
            log: { logged.add($0) },
            send: server.send
        )
    }

    private func pageEvent(_ queue: EventQueue, _ screen: String) {
        queue.enqueue(endpoint: eventUrl, payload: [
            "campaign_id": "11111111-1111-1111-1111-111111111111",
            "device_id": "device-A",
            "events": [[
                "type": "screen_view",
                "timestamp": "2026-11-01T12:00:00Z",
                "screen": screen,
                "event_id": UUID().uuidString.lowercased(),
            ]],
        ])
    }

    private func purchase(_ queue: EventQueue) {
        queue.enqueue(endpoint: purchaseUrl, payload: ["campaign_id": "app", "device_id": "device-A", "transaction_id": "tx"])
    }

    func testServerErrorKeepsTheEventsAndWaits() async {
        server.reply = { _ in EventQueue.Answer(status: 503) }
        let queue = makeQueue()
        pageEvent(queue, "Home")

        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 1)
        XCTAssertEqual(queue.pending.map(\.retries), [1])

        // Not before the 5 s wait is over, flush() or not.
        clock.advance(by: 4.9)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 1)

        server.reply = { _ in EventQueue.Answer(status: 200) }
        clock.advance(by: 0.1)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 2)
        XCTAssertEqual(queue.size, 0)
        XCTAssertTrue(logged.lines.isEmpty)
    }

    func testRetryAfterSecondsIsHonored() async {
        server.reply = { _ in EventQueue.Answer(status: 429, retryAfter: "30") }
        let queue = makeQueue()
        pageEvent(queue, "Home")

        await queue.flush()
        clock.advance(by: 29)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 1)

        clock.advance(by: 1)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 2)
    }

    func testRetryAfterDateIsHonored() async {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let at = format.string(from: clock.now.addingTimeInterval(90))
        server.reply = { _ in EventQueue.Answer(status: 503, retryAfter: at) }
        let queue = makeQueue()
        pageEvent(queue, "Home")

        await queue.flush()
        clock.advance(by: 89)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 1)

        clock.advance(by: 1)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, 2)
    }

    func testWaitDoublesUpToFiveMinutesAndNothingIsDropped() async {
        server.reply = { _ in EventQueue.Answer(status: 500) }
        let queue = makeQueue()
        pageEvent(queue, "Home")
        let id = queue.pending.map(\.id)

        var tries = 0
        for wait in [5.0, 10, 20, 40, 80, 160, 300, 300, 300] as [TimeInterval] {
            await queue.flush()
            tries += 1
            XCTAssertEqual(server.endpoints.count, tries)
            // A second short of the wait: nothing goes.
            clock.advance(by: wait - 1)
            await queue.flush()
            XCTAssertEqual(server.endpoints.count, tries, "wait \(wait)")
            clock.advance(by: 1)
        }
        XCTAssertEqual(queue.pending.map(\.id), id)
        XCTAssertEqual(queue.pending.map(\.retries), [9])
    }

    func testNoAnswerKeepsTheEvents() async {
        server.reply = { _ in EventQueue.Answer(status: nil) }
        let queue = makeQueue()
        pageEvent(queue, "Home")

        await queue.flush()
        XCTAssertEqual(queue.pending.map(\.retries), [1])
        XCTAssertTrue(logged.lines.isEmpty)
    }

    func testNotFoundAndTimeoutAreKept() async {
        for status in [404, 408] {
            server.reply = { _ in EventQueue.Answer(status: status) }
            let queue = makeQueue()
            queue.clear()
            pageEvent(queue, "Home")
            await queue.flush()
            XCTAssertEqual(queue.size, 1, "\(status)")
            clock.advance(by: 600)
        }
        XCTAssertTrue(logged.lines.isEmpty)
    }

    func testRefusalDropsWithOneLogLineAndTheFlushCarriesOn() async {
        server.reply = { endpoint in EventQueue.Answer(status: endpoint.hasSuffix("/purchase") ? 400 : 200) }
        let queue = makeQueue()
        purchase(queue)
        pageEvent(queue, "Home")

        await queue.flush()

        XCTAssertEqual(server.endpoints, [purchaseUrl, eventUrl])
        XCTAssertEqual(queue.size, 0)
        XCTAssertEqual(logged.lines.count, 1)
        XCTAssertTrue(logged.lines[0].contains("HTTP 400"), logged.lines[0])
        XCTAssertTrue(logged.lines[0].contains("/api/v1/mobile/purchase"), logged.lines[0])

        // And no wait after a refusal.
        server.reply = { _ in EventQueue.Answer(status: 413) }
        pageEvent(queue, "Big")
        await queue.flush()
        XCTAssertEqual(queue.size, 0)
        XCTAssertEqual(logged.lines.count, 2)
    }

    func testSentResetsTheWait() async {
        server.reply = { _ in EventQueue.Answer(status: 500) }
        let queue = makeQueue()
        pageEvent(queue, "A")
        await queue.flush()
        clock.advance(by: 5)
        await queue.flush()

        server.reply = { _ in EventQueue.Answer(status: 200) }
        clock.advance(by: 10)
        await queue.flush()
        XCTAssertEqual(queue.size, 0)

        // The next failure waits 5 s again, not 20 s.
        server.reply = { _ in EventQueue.Answer(status: 500) }
        pageEvent(queue, "B")
        await queue.flush()
        let count = server.endpoints.count
        clock.advance(by: 5)
        await queue.flush()
        XCTAssertEqual(server.endpoints.count, count + 1)
    }

    func testSizeCapStillDropsTheOldest() async {
        server.reply = { _ in EventQueue.Answer(status: 503) }
        let queue = makeQueue(maxQueueSize: 10)
        for i in 0..<12 {
            pageEvent(queue, "S\(i)")
            await queue.flush()
            clock.advance(by: 600)
        }
        let screens = queue.pending.map { entry -> String? in
            let body = (try? JSONSerialization.jsonObject(with: entry.payloadJson)) as? [String: Any]
            return ((body?["events"] as? [[String: Any]])?.first)?["screen"] as? String
        }
        XCTAssertEqual(screens, (2..<12).map { "S\($0)" })
    }
}

/// A clock the tests move by hand.
final class TestClock {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// The queue's debug lines.
private final class LogLines {
    private let lock = NSLock()
    private var recorded: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func add(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(line)
    }
}

/// Records every request's endpoint and answers with `reply`.
private final class AnswerServer {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var replyFor: (String) -> EventQueue.Answer = { _ in EventQueue.Answer(status: 200) }

    var endpoints: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var reply: (String) -> EventQueue.Answer {
        get { lock.lock(); defer { lock.unlock() }; return replyFor }
        set { lock.lock(); defer { lock.unlock() }; replyFor = newValue }
    }

    func send(_ endpoint: String, _ body: Data) async -> EventQueue.Answer {
        lock.lock()
        recorded.append(endpoint)
        let reply = replyFor
        lock.unlock()
        return reply(endpoint)
    }
}
