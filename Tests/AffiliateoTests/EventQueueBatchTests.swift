import XCTest
@testable import Affiliateo

/// 4.16.1: a flush sends the queued events of one app and device in one
/// request to /api/v1/mobile/event (at most 100 events, body at most 60,000
/// bytes) instead of one request each. Every other endpoint still gets a
/// request per entry, in queue order, and entries that shared a request share
/// its outcome.
final class EventQueueBatchTests: XCTestCase {
    private let api = "https://affiliateo.com"
    private var eventUrl: String { "\(api)/api/v1/mobile/event" }
    private let app = "11111111-1111-1111-1111-111111111111"
    private let device = "device-A"

    // MARK: Helpers

    /// A queued entry shaped exactly like the one page(_:) queues.
    private func eventEntry(
        app: String? = nil,
        device: String? = nil,
        endpoint: String? = nil,
        screen: String = "Home",
        metadata: [String: Any]? = nil,
        count: Int = 1,
        retries: Int = 0
    ) -> EventQueue.QueuedEvent {
        let events: [[String: Any]] = (0..<count).map { i in
            var event: [String: Any] = [
                "type": "screen_view",
                "timestamp": "2026-10-31T12:00:\(String(format: "%02d", i % 60))Z",
                "screen": count == 1 ? screen : "\(screen)-\(i)",
                "event_id": UUID().uuidString.lowercased(),
            ]
            if let metadata { event["metadata"] = metadata }
            return event
        }
        return entry(endpoint: endpoint ?? eventUrl, payload: [
            "campaign_id": app ?? self.app,
            "device_id": device ?? self.device,
            "events": events,
        ], retries: retries)
    }

    private func entry(endpoint: String, payload: [String: Any], retries: Int = 0) -> EventQueue.QueuedEvent {
        EventQueue.QueuedEvent(
            id: UUID().uuidString,
            endpoint: endpoint,
            payloadJson: try! JSONSerialization.data(withJSONObject: payload),
            retries: retries
        )
    }

    private func purchaseEntry(_ tx: String = "tx-1") -> EventQueue.QueuedEvent {
        entry(endpoint: "\(api)/api/v1/mobile/purchase", payload: [
            "campaign_id": app, "device_id": device, "transaction_id": tx,
            "product_id": "pro", "price": "9.99", "currency": "USD", "kind": "subscription", "platform": "ios",
        ])
    }

    private func adIdsEntry() -> EventQueue.QueuedEvent {
        entry(endpoint: "\(api)/api/v1/mobile/ad-ids", payload: [
            "campaign_id": app, "device_id": device, "tracking_allowed": true,
        ])
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func events(_ data: Data) -> [NSDictionary] {
        (json(data)["events"] as? [NSDictionary]) ?? []
    }

    /// The events of these entries in queue order, as queued.
    private func queuedEvents(_ entries: [EventQueue.QueuedEvent]) -> [NSDictionary] {
        entries.flatMap { events($0.payloadJson) }
    }

    // MARK: plan(_:)

    func testSameDeviceMergesIntoOneRequest() {
        let entries = [eventEntry(screen: "Home"), eventEntry(screen: "Paywall"), eventEntry(screen: "Settings")]
        let plan = EventQueue.plan(entries)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].endpoint, eventUrl)
        XCTAssertEqual(plan[0].entryIds, entries.map(\.id))
        let body = json(plan[0].body)
        XCTAssertEqual(body["campaign_id"] as? String, app)
        XCTAssertEqual(body["device_id"] as? String, device)
        XCTAssertEqual(Set(body.keys), ["campaign_id", "device_id", "events"])
        // Every event as queued, in order: same event_id, timestamp, screen.
        XCTAssertEqual(events(plan[0].body), queuedEvents(entries))
        XCTAssertEqual(events(plan[0].body).map { $0["screen"] as? String }, ["Home", "Paywall", "Settings"])
    }

    func testEventFieldsKeptExactly() {
        let metadata: [String: Any] = [
            "plan": "yearly", "price": 59.99, "count": 3, "trial": true, "ratio": 0.1,
            "path": "a/b", "name": "Zo\u{00EB} \u{1F600}", "nested": ["k": [1, 2, 3]],
        ]
        let entries = [eventEntry(metadata: metadata), eventEntry(metadata: metadata)]
        let plan = EventQueue.plan(entries)

        XCTAssertEqual(plan.count, 1)
        let sent = events(plan[0].body)
        XCTAssertEqual(sent, queuedEvents(entries))
        XCTAssertEqual(sent[0]["event_id"] as? String, events(entries[0].payloadJson)[0]["event_id"] as? String)
        XCTAssertEqual(sent[1]["timestamp"] as? String, events(entries[1].payloadJson)[0]["timestamp"] as? String)
        XCTAssertEqual((sent[0]["metadata"] as? NSDictionary)?["price"] as? Double, 59.99)
        XCTAssertEqual((sent[0]["metadata"] as? NSDictionary)?["name"] as? String, "Zo\u{00EB} \u{1F600}")
    }

    func testDifferentDeviceOrAppNotMerged() {
        let a = eventEntry(device: "device-A")
        let b = eventEntry(device: "device-B")
        let c = eventEntry(device: "device-B")
        let d = eventEntry(app: "22222222-2222-2222-2222-222222222222", device: "device-B")
        let e = eventEntry(device: "device-B", endpoint: "https://staging.affiliateo.com/api/v1/mobile/event")
        let plan = EventQueue.plan([a, b, c, d, e])

        XCTAssertEqual(plan.map(\.entryIds), [[a.id], [b.id, c.id], [d.id], [e.id]])
        XCTAssertEqual(plan.map(\.endpoint), [eventUrl, eventUrl, eventUrl, "https://staging.affiliateo.com/api/v1/mobile/event"])
        XCTAssertEqual(json(plan[1].body)["device_id"] as? String, "device-B")
        XCTAssertEqual(json(plan[2].body)["campaign_id"] as? String, "22222222-2222-2222-2222-222222222222")
    }

    func testOnlyConsecutiveEntriesMerge() {
        let a = eventEntry(device: "device-A")
        let b = eventEntry(device: "device-B")
        let c = eventEntry(device: "device-A")
        let plan = EventQueue.plan([a, b, c])
        XCTAssertEqual(plan.map(\.entryIds), [[a.id], [b.id], [c.id]])
    }

    func testHundredEventCapSplits() {
        let entries = (0..<250).map { _ in eventEntry() }
        let plan = EventQueue.plan(entries)

        XCTAssertEqual(plan.map { $0.entryIds.count }, [100, 100, 50])
        XCTAssertEqual(plan.map { events($0.body).count }, [100, 100, 50])
        XCTAssertEqual(plan.flatMap(\.entryIds), entries.map(\.id))
        XCTAssertEqual(plan.flatMap { events($0.body) }, queuedEvents(entries))
        XCTAssertTrue(plan.allSatisfy { $0.body.count <= EventQueue.maxBodyBytes })
    }

    func testHundredEventCapCountsEventsNotEntries() {
        // 60 + 30 fit; adding 20 more would make 110, so a new request starts.
        let a = eventEntry(count: 60)
        let b = eventEntry(count: 30)
        let c = eventEntry(count: 20)
        let plan = EventQueue.plan([a, b, c])
        XCTAssertEqual(plan.map(\.entryIds), [[a.id, b.id], [c.id]])
        XCTAssertEqual(plan.map { events($0.body).count }, [90, 20])
    }

    func testSizeCapSplits() {
        // About 2.1 KB per event: 100 of them would be over 200 KB.
        let big: [String: Any] = ["blob": String(repeating: "x", count: 2_000)]
        let entries = (0..<100).map { _ in eventEntry(metadata: big) }
        let plan = EventQueue.plan(entries)

        XCTAssertGreaterThan(plan.count, 3)
        for delivery in plan {
            XCTAssertLessThanOrEqual(delivery.body.count, EventQueue.maxBodyBytes)
            XCTAssertLessThanOrEqual(events(delivery.body).count, EventQueue.maxEventsPerRequest)
        }
        // Each request is filled up to the cap: one more event would not fit.
        let perEvent = plan[0].body.count / plan[0].entryIds.count
        XCTAssertGreaterThan(plan[0].body.count + perEvent, EventQueue.maxBodyBytes)
        XCTAssertEqual(plan.flatMap(\.entryIds), entries.map(\.id))
        XCTAssertEqual(plan.flatMap { events($0.body) }, queuedEvents(entries))
    }

    func testSizeCapIsExactOnTheBody() {
        let entries = (0..<10).map { _ in eventEntry() }
        let two = EventQueue.plan(Array(entries.prefix(2)))[0].body.count
        let three = EventQueue.plan(Array(entries.prefix(3)))[0].body.count

        // A cap of exactly the three-entry body keeps three together...
        let atCap = EventQueue.plan(entries, maxBytes: three)
        XCTAssertEqual(atCap.map { $0.entryIds.count }, [3, 3, 3, 1])
        XCTAssertTrue(atCap.allSatisfy { $0.body.count <= three })
        // ...and one byte less splits after two.
        let underCap = EventQueue.plan(entries, maxBytes: three - 1)
        XCTAssertEqual(underCap.map { $0.entryIds.count }, [2, 2, 2, 2, 2])
        XCTAssertTrue(underCap.allSatisfy { $0.body.count <= two })
    }

    func testEntryOverACapOnItsOwnGoesAloneAsQueued() {
        let huge = eventEntry(metadata: ["blob": String(repeating: "y", count: 70_000)])
        let many = eventEntry(count: 120)
        let before = eventEntry()
        let after = eventEntry()
        let plan = EventQueue.plan([before, huge, many, after])

        XCTAssertEqual(plan.map(\.entryIds), [[before.id], [huge.id], [many.id], [after.id]])
        XCTAssertEqual(plan[1].body, huge.payloadJson)
        XCTAssertEqual(plan[2].body, many.payloadJson)
    }

    func testLoneEntrySentExactlyAsQueued() {
        let only = eventEntry()
        let plan = EventQueue.plan([only])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].body, only.payloadJson)
        XCTAssertEqual(plan[0].entryIds, [only.id])
    }

    func testOtherEndpointsNeverMergedAndKeepOrder() {
        let e1 = eventEntry(), e2 = eventEntry()
        let p1 = purchaseEntry("tx-1"), p2 = purchaseEntry("tx-2")
        let e3 = eventEntry()
        let ad1 = adIdsEntry(), ad2 = adIdsEntry()
        let e4 = eventEntry(), e5 = eventEntry()
        let plan = EventQueue.plan([e1, e2, p1, p2, e3, ad1, ad2, e4, e5])

        XCTAssertEqual(plan.map(\.entryIds), [[e1.id, e2.id], [p1.id], [p2.id], [e3.id], [ad1.id], [ad2.id], [e4.id, e5.id]])
        XCTAssertEqual(plan[1].endpoint, "\(api)/api/v1/mobile/purchase")
        XCTAssertEqual(plan[1].body, p1.payloadJson)
        XCTAssertEqual(plan[2].body, p2.payloadJson)
        XCTAssertEqual(plan[4].endpoint, "\(api)/api/v1/mobile/ad-ids")
        XCTAssertEqual(plan[4].body, ad1.payloadJson)
        XCTAssertEqual(plan[5].body, ad2.payloadJson)
    }

    func testEventEntryWithOtherFieldsIsNotMerged() {
        let plain = eventEntry()
        let extra = entry(endpoint: eventUrl, payload: [
            "campaign_id": app, "device_id": device, "something": 1,
            "events": [["type": "custom", "event_id": UUID().uuidString.lowercased()]],
        ])
        let broken = EventQueue.QueuedEvent(id: UUID().uuidString, endpoint: eventUrl, payloadJson: Data("not json".utf8), retries: 0)
        let plain2 = eventEntry()
        let plan = EventQueue.plan([plain, extra, broken, plain2])

        XCTAssertEqual(plan.map(\.entryIds), [[plain.id], [extra.id], [broken.id], [plain2.id]])
        XCTAssertEqual(plan[1].body, extra.payloadJson)
        XCTAssertEqual(plan[2].body, broken.payloadJson)
    }

    // MARK: flush()

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "affiliateo-event-queue-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// No jitter, so a kept answer's wait is exactly 5 s, 10 s, 20 s...
    private func makeQueue(_ server: FakeServer, clock: TestClock = TestClock()) -> EventQueue {
        EventQueue(userDefaults: defaults, autoFlush: false, now: { clock.now }, jitter: { 0 }, send: server.send)
    }

    private func pageEvent(_ queue: EventQueue, _ screen: String) {
        queue.enqueue(endpoint: eventUrl, payload: [
            "campaign_id": app,
            "device_id": device,
            "events": [[
                "type": "screen_view",
                "timestamp": "2026-10-31T12:00:00Z",
                "screen": screen,
                "event_id": UUID().uuidString.lowercased(),
            ]],
        ])
    }

    func testFlushSendsOneRequestForTheEvents() async {
        let server = FakeServer()
        let queue = makeQueue(server)
        for screen in ["Home", "Feed", "Paywall"] { pageEvent(queue, screen) }
        queue.enqueue(endpoint: "\(api)/api/v1/mobile/purchase", payload: ["campaign_id": app, "device_id": device, "transaction_id": "tx"])
        pageEvent(queue, "Thanks")

        await queue.flush()

        XCTAssertEqual(server.requests.map(\.endpoint), [eventUrl, "\(api)/api/v1/mobile/purchase", eventUrl])
        XCTAssertEqual(events(server.requests[0].body).map { $0["screen"] as? String }, ["Home", "Feed", "Paywall"])
        XCTAssertEqual(events(server.requests[2].body).map { $0["screen"] as? String }, ["Thanks"])
        XCTAssertEqual(queue.size, 0)
    }

    func testFailureKeepsEveryMergedEntry() async {
        let server = FakeServer()
        server.answer = { _ in false }
        let clock = TestClock()
        let queue = makeQueue(server, clock: clock)
        for screen in ["A", "B", "C", "D"] { pageEvent(queue, screen) }
        let ids = queue.pending.map(\.id)

        await queue.flush()
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(queue.pending.map(\.id), ids)
        XCTAssertEqual(queue.pending.map(\.retries), [1, 1, 1, 1])
        // Saved with their retries, as a single entry always was.
        let saved = try! JSONDecoder().decode([EventQueue.QueuedEvent].self, from: defaults.data(forKey: "affiliateo_event_queue")!)
        XCTAssertEqual(saved.map(\.retries), [1, 1, 1, 1])

        // The retry, once the 5 s wait is over (4.16.2), resends the same
        // events (same event_id), so the server's dedup makes a lost
        // response safe.
        clock.advance(by: 5)
        await queue.flush()
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(events(server.requests[1].body), events(server.requests[0].body))
        XCTAssertEqual(queue.pending.map(\.retries), [2, 2, 2, 2])

        // A third failed try no longer drops them (4.16.2): they wait on.
        clock.advance(by: 10)
        await queue.flush()
        XCTAssertEqual(server.requests.count, 3)
        XCTAssertEqual(queue.pending.map(\.id), ids)
        XCTAssertEqual(queue.pending.map(\.retries), [3, 3, 3, 3])
    }

    func testEachEntryKeepsItsOwnRetryCount() async {
        // Two event entries already queued (say from the last launch), one of
        // them with two failed tries behind it. Its third no longer drops it
        // (4.16.2).
        let old = eventEntry(screen: "Old", retries: 2)
        let fresh = eventEntry(screen: "Fresh", retries: 0)
        defaults.set(try! JSONEncoder().encode([old, fresh]), forKey: "affiliateo_event_queue")
        let server = FakeServer()
        server.answer = { _ in false }
        let queue = makeQueue(server)

        await queue.flush()

        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(events(server.requests[0].body).count, 2)
        XCTAssertEqual(queue.pending.map(\.id), [old.id, fresh.id])
        XCTAssertEqual(queue.pending.map(\.retries), [3, 1])
    }

    func testKeptRequestHoldsBackTheRestInOrder() async {
        let server = FakeServer()
        server.answer = { endpoint in !endpoint.hasSuffix("/purchase") }
        let clock = TestClock()
        let queue = makeQueue(server, clock: clock)
        let purchaseUrl = "\(api)/api/v1/mobile/purchase"
        pageEvent(queue, "A")
        pageEvent(queue, "B")
        queue.enqueue(endpoint: purchaseUrl, payload: ["campaign_id": app, "device_id": device, "transaction_id": "tx"])
        pageEvent(queue, "C")

        await queue.flush()

        // A and B went; the purchase is kept, and C waits behind it (4.16.2).
        XCTAssertEqual(server.requests.map(\.endpoint), [eventUrl, purchaseUrl])
        XCTAssertEqual(queue.pending.map(\.endpoint), [purchaseUrl, eventUrl])
        XCTAssertEqual(queue.pending.map(\.retries), [1, 0])

        // The next try, after the wait, sends both, purchase first.
        server.answer = { _ in true }
        clock.advance(by: 5)
        await queue.flush()
        XCTAssertEqual(server.requests.map(\.endpoint), [eventUrl, purchaseUrl, purchaseUrl, eventUrl])
        XCTAssertEqual(events(server.requests[3].body).map { $0["screen"] as? String }, ["C"])
        XCTAssertEqual(queue.size, 0)
    }

    func testSuccessRemovesEveryMergedEntryAndSaves() async {
        let server = FakeServer()
        let queue = makeQueue(server)
        for i in 0..<9 { pageEvent(queue, "S\(i)") }

        await queue.flush()

        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(events(server.requests[0].body).count, 9)
        XCTAssertEqual(queue.size, 0)
        let saved = try! JSONDecoder().decode([EventQueue.QueuedEvent].self, from: defaults.data(forKey: "affiliateo_event_queue")!)
        XCTAssertTrue(saved.isEmpty)
    }
}

/// Records every request a flush makes and answers 200, or a 500 (kept,
/// see SendRetry.swift) where `answer` says no.
private final class FakeServer {
    struct Request {
        let endpoint: String
        let body: Data
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    var answer: (String) -> Bool = { _ in true }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ endpoint: String, _ body: Data) async -> EventQueue.Answer {
        lock.lock()
        recorded.append(Request(endpoint: endpoint, body: body))
        let answer = self.answer
        lock.unlock()
        return EventQueue.Answer(status: answer(endpoint) ? 200 : 500)
    }
}
