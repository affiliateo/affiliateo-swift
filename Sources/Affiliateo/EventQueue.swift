import Foundation
#if canImport(Network)
import Network
#endif

/// EventQueue: durable best-effort delivery for analytics events.
///
/// Mirrors the @affiliateo/web and @affiliateo/react-native queues so all
/// three platforms behave consistently for merchants integrating across
/// web + RN + native iOS. The queue is per-process (singleton'd by the
/// Manager) and persists pending events to UserDefaults so they survive
/// app close / kill.
///
/// Architecture:
///   - In-memory `queue` array of QueuedEvent (id + request descriptor + retries)
///   - Persisted to UserDefaults under STORAGE_KEY as JSON on every mutation
///   - Background Timer fires every FLUSH_INTERVAL_SECS to attempt delivery
///   - A flush sends consecutive /mobile/event entries for the same app and
///     device as ONE request (4.16.1, see `plan(_:)`); every other entry
///     still goes alone, in queue order
///   - NWPathMonitor pauses flushing while offline; an immediate flush
///     fires the moment connectivity returns (no waiting for the timer)
///   - Failed events bump a per-event retry counter; dropped after MAX_RETRIES.
///     Entries that shared a request share its outcome: all leave on a 2xx,
///     all stay (each counting a try) otherwise
///
/// Why UserDefaults instead of FileManager / Keychain:
///   UserDefaults is the platform-idiomatic key-value store for small
///   structured data (think <1MB). At 100 events × ~500 bytes each
///   we're at 50 KB max, well inside UserDefaults' comfort zone.
///   FileManager would add async I/O overhead for no real benefit.
///
/// Caps (matched to web + RN for cross-platform consistency):
///   - maxRetries = 3
///   - maxQueueSize = 100      hard cap, FIFO drop on overflow
///   - flushIntervalSecs = 5   periodic auto-flush cadence
///   - sizeFlushThreshold = 10 trigger flush when queue grows past
final class EventQueue {
    // Wire format. Codable so JSONEncoder/JSONDecoder roundtrip works
    // for persistence. `payload` stored as Data (JSON-encoded) so we
    // don't need an Any-friendly Codable wrapper — the SDK builds the
    // payload as a [String: Any] dictionary, we serialize it once at
    // enqueue time and replay verbatim on flush.
    struct QueuedEvent: Codable {
        let id: String
        let endpoint: String
        let payloadJson: Data
        var retries: Int
    }

    /// Sends one request body to one endpoint and answers whether it landed
    /// (a 2xx). The SDK uses `post(endpoint:body:)`; tests pass their own.
    typealias Sender = (_ endpoint: String, _ body: Data) async -> Bool

    /// One request of a flush (4.16.1): the body it sends and the queued
    /// entries it carries. They leave the queue together on a 2xx, and stay
    /// together otherwise.
    struct Delivery {
        let endpoint: String
        let body: Data
        let entryIds: [String]
    }

    /// Caps on one merged /mobile/event request (4.16.1). The server refuses
    /// more than 100 events (a 400) and a body over 64 KB (a 413); 60,000
    /// bytes leaves a margin under the second.
    static let maxEventsPerRequest = 100
    static let maxBodyBytes = 60_000

    private let storageKey = "affiliateo_event_queue"
    private let maxRetries = 3
    private let sizeFlushThreshold = 10
    // Configurable via init(flushIntervalSecs:maxQueueSize:). Defaults
    // match the rest of the SDK family (web, RN, Kotlin, Flutter).
    // Bounded inputs in the init guard against pathological values
    // (refuse <1s flush so we don't hammer the network, refuse >60s so
    // the queue actually drains; min 10 / max 1000 on size cap).
    private let maxQueueSize: Int
    private let flushIntervalSecs: TimeInterval

    private let userDefaults: UserDefaults
    private let autoFlush: Bool
    private let send: Sender
    private var queue: [QueuedEvent] = []
    private var flushTimer: Timer?
    private var isFlushing = false
    private var shuttingDown = false
    // Optimistic default. NWPathMonitor's first callback flips this to
    // the real value within a few hundred ms of init.
    private var isConnected = true

    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.affiliateo.network")
    #endif

    // Serial queue for all mutations so we never race a flush against an
    // enqueue. Cheap on iOS; the alternative would be a NSLock around
    // every field, which is more error-prone.
    private let serialQueue = DispatchQueue(label: "com.affiliateo.queue")

    /// `autoFlush: false` (tests only) starts no timer and no network
    /// monitor and never flushes on its own: only `flush()` sends.
    init(
        userDefaults: UserDefaults = .standard,
        flushIntervalSecs: TimeInterval = 5,
        maxQueueSize: Int = 100,
        autoFlush: Bool = true,
        send: @escaping Sender = EventQueue.post(endpoint:body:)
    ) {
        self.userDefaults = userDefaults
        // Clamp to sane bounds so a misconfigured host can't break the queue.
        self.flushIntervalSecs = max(1, min(60, flushIntervalSecs))
        self.maxQueueSize = max(10, min(1000, maxQueueSize))
        self.autoFlush = autoFlush
        self.send = send
        loadFromDisk()
        guard autoFlush else { return }
        startNetworkMonitor()
        startFlushTimer()
        // Catch-up flush on init in case the previous app session ended
        // with events still queued. Best-effort: noops when offline.
        if !queue.isEmpty {
            scheduleFlush()
        }
    }

    /// Add an event to the queue. Returns immediately; persistence happens
    /// asynchronously on the serial queue.
    func enqueue(endpoint: String, payload: [String: Any]) {
        guard !shuttingDown else { return }
        // Serialize the payload synchronously so we don't capture a
        // mutable dictionary that could be modified by the caller after
        // enqueue returns. JSONSerialization is the cheapest path for
        // an [String: Any] payload.
        guard let payloadJson = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        let event = QueuedEvent(
            id: UUID().uuidString,
            endpoint: endpoint,
            payloadJson: payloadJson,
            retries: 0
        )
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.queue.append(event)
            // FIFO drop when over cap. Network outage edge case: under
            // sustained failure the queue would grow until UserDefaults
            // started complaining. 100 events is a sane upper bound.
            if self.queue.count > self.maxQueueSize {
                self.queue.removeFirst(self.queue.count - self.maxQueueSize)
            }
            self.persist()
            if self.autoFlush && self.queue.count >= self.sizeFlushThreshold {
                self.scheduleFlush()
            }
        }
    }

    /// Try to deliver every queued event. Each event gets one attempt
    /// per flush; failures bump retries and stay queued. Events that
    /// hit maxRetries are dropped. Skipped entirely when offline.
    /// Since 4.16.1 the events of one flush share requests (see `plan(_:)`),
    /// and the call returns once the queue is saved.
    func flush() async {
        // Capture the work to do atomically off the serial queue, so the
        // network calls don't block other enqueue/flush calls.
        let snapshot: [QueuedEvent] = await withCheckedContinuation { cont in
            serialQueue.async { [weak self] in
                guard let self = self else { cont.resume(returning: []); return }
                if self.isFlushing || self.queue.isEmpty || !self.isConnected {
                    cont.resume(returning: [])
                    return
                }
                self.isFlushing = true
                cont.resume(returning: self.queue)
            }
        }
        if snapshot.isEmpty { return }

        // One request per Delivery: the snapshot's events go out together,
        // per app and device, instead of one request each (4.16.1). Still
        // sequential, so the server sees everything in queue order and the
        // retry rules stay simple. Head-of-line blocking is fine because all
        // requests go to the same server and the snapshot is bounded.
        for delivery in EventQueue.plan(snapshot) {
            let ok = await send(delivery.endpoint, delivery.body)
            await applyResult(entryIds: delivery.entryIds, ok: ok)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            serialQueue.async { [weak self] in
                self?.persist()
                self?.isFlushing = false
                cont.resume()
            }
        }
    }

    /// Turns a flush's snapshot into its requests, in queue order (4.16.1).
    ///
    /// Consecutive /mobile/event entries for the same endpoint, app
    /// (campaign_id) and device go in one request, their `events` arrays
    /// joined in order: at most `maxEvents` events and `maxBytes` of body, and
    /// a new request starts where either cap would be passed. Each event keeps
    /// its own fields (event_id, timestamp, screen, metadata) as queued.
    ///
    /// Every other entry (ad ids, purchases, and an event entry that holds
    /// anything besides campaign_id, device_id and events) is a request of
    /// its own, exactly as queued, and keeps its place between the events.
    /// A request that carries one entry sends that entry's queued bytes, so an
    /// entry already over a cap on its own is sent as it always was.
    static func plan(
        _ entries: [QueuedEvent],
        maxEvents: Int = maxEventsPerRequest,
        maxBytes: Int = maxBodyBytes
    ) -> [Delivery] {
        var deliveries: [Delivery] = []
        var batch: EventBatch?

        for entry in entries {
            guard let parts = EventParts(entry) else {
                if let open = batch { deliveries.append(open.delivery()) }
                batch = nil
                deliveries.append(Delivery(endpoint: entry.endpoint, body: entry.payloadJson, entryIds: [entry.id]))
                continue
            }
            if var open = batch, open.accepts(parts, maxEvents: maxEvents, maxBytes: maxBytes) {
                open.add(parts)
                batch = open
            } else {
                if let open = batch { deliveries.append(open.delivery()) }
                batch = EventBatch(parts)
            }
        }
        if let open = batch { deliveries.append(open.delivery()) }
        return deliveries
    }

    /// Wipe all queued events. Called by reset() and optOut().
    func clear() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.queue.removeAll()
            self.userDefaults.removeObject(forKey: self.storageKey)
        }
    }

    /// Stop the timer + network monitor. Idempotent. Best-effort
    /// last flush attempt. Anything still queued persists to disk.
    func shutdown() {
        shuttingDown = true
        flushTimer?.invalidate()
        flushTimer = nil
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        #endif
        Task { await self.flush() }
    }

    /// Read-only count. Used by tests / debug helpers.
    var size: Int {
        serialQueue.sync { queue.count }
    }

    /// Read-only copy of the queue, retries included. Used by tests.
    var pending: [QueuedEvent] {
        serialQueue.sync { queue }
    }

    // MARK: - Private

    private func loadFromDisk() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([QueuedEvent].self, from: data) {
            queue = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(queue) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushIntervalSecs, repeats: true) { [weak self] _ in
            self?.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        Task { await self.flush() }
    }

    private func startNetworkMonitor() {
        #if canImport(Network)
        // NWPathMonitor is iOS 12+ / macOS 10.14+; both well below our
        // minimum target. The first update callback fires within a few
        // hundred ms of start() and gives us the real current state.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let wasOffline = !self.isConnected
            self.isConnected = path.status == .satisfied
            if wasOffline && self.isConnected {
                // Came back online — catch-up flush right now instead
                // of waiting up to flushIntervalSecs for the timer.
                self.scheduleFlush()
            }
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor
        #endif
    }

    /// The SDK's Sender: one POST with a JSON body.
    static func post(endpoint: String, body: Data) async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// One request's outcome for every entry it carried: all removed on a
    /// 2xx; otherwise each stays and counts a try, the way a lone entry
    /// always did, and one that reaches maxRetries is dropped.
    private func applyResult(entryIds: [String], ok: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            serialQueue.async { [weak self] in
                guard let self = self else { cont.resume(); return }
                if ok {
                    let sent = Set(entryIds)
                    self.queue.removeAll { sent.contains($0.id) }
                } else {
                    for id in entryIds {
                        // Gone already when clear() or the size cap ran meanwhile.
                        guard let idx = self.queue.firstIndex(where: { $0.id == id }) else { continue }
                        self.queue[idx].retries += 1
                        if self.queue[idx].retries >= self.maxRetries {
                            self.queue.remove(at: idx)
                        }
                    }
                }
                cont.resume()
            }
        }
    }
}

// MARK: - Merging events (4.16.1)

private let mobileEventPath = "/api/v1/mobile/event"

/// A queued /mobile/event entry taken apart for merging: its app, its device
/// and each of its events as JSON. Nil for an entry of another endpoint, and
/// for one that does not read as exactly campaign_id, device_id and a
/// non-empty events array of objects (it is then sent alone, as queued).
private struct EventParts {
    let entry: EventQueue.QueuedEvent
    let campaignId: String
    let deviceId: String
    let events: [Data]
    /// The events' bytes, without the commas between them.
    let eventBytes: Int
    /// The merged body's start, `{"campaign_id":..,"device_id":..,"events":[`.
    let head: Data

    init?(_ entry: EventQueue.QueuedEvent) {
        guard entry.endpoint.hasSuffix(mobileEventPath),
              let payload = (try? JSONSerialization.jsonObject(with: entry.payloadJson)) as? [String: Any],
              Set(payload.keys) == ["campaign_id", "device_id", "events"],
              let campaignId = payload["campaign_id"] as? String,
              let deviceId = payload["device_id"] as? String,
              let events = payload["events"] as? [[String: Any]],
              !events.isEmpty
        else { return nil }
        guard let head = EventParts.head(campaignId, deviceId) else { return nil }
        var blobs: [Data] = []
        blobs.reserveCapacity(events.count)
        for event in events {
            // Each event is written back as the object it was parsed from: the
            // same fields and values, so its event_id and timestamp are the ones
            // stamped when it was queued.
            guard let blob = try? JSONSerialization.data(withJSONObject: event) else { return nil }
            blobs.append(blob)
        }
        self.entry = entry
        self.campaignId = campaignId
        self.deviceId = deviceId
        self.events = blobs
        self.eventBytes = blobs.reduce(0) { $0 + $1.count }
        self.head = head
    }

    private static func head(_ campaignId: String, _ deviceId: String) -> Data? {
        guard let campaign = jsonString(campaignId), let device = jsonString(deviceId) else { return nil }
        var head = Data("{\"campaign_id\":".utf8)
        head.append(campaign)
        head.append(Data(",\"device_id\":".utf8))
        head.append(device)
        head.append(Data(",\"events\":[".utf8))
        return head
    }

    /// A string as a JSON string literal, escaped by JSONSerialization.
    private static func jsonString(_ value: String) -> Data? {
        // Wrapped in an array (a top-level string is not valid input), then
        // the brackets dropped.
        guard let array = try? JSONSerialization.data(withJSONObject: [value]), array.count >= 2 else {
            return nil
        }
        return array.subdata(in: 1..<(array.count - 1))
    }
}

/// The /mobile/event request a flush is filling: the body is
/// {"campaign_id":..,"device_id":..,"events":[e1,e2,...]}, and its size is
/// counted as entries join, so it is known before a cap would be passed.
private struct EventBatch {
    let endpoint: String
    let campaignId: String
    let deviceId: String
    let head: Data
    private(set) var parts: [EventParts]
    private(set) var eventCount: Int
    /// Bytes of the merged body as it stands.
    private(set) var bodyBytes: Int

    init(_ first: EventParts) {
        endpoint = first.entry.endpoint
        campaignId = first.campaignId
        deviceId = first.deviceId
        head = first.head
        parts = [first]
        eventCount = first.events.count
        // The envelope, the events, and a comma between each two of them.
        bodyBytes = first.head.count + EventBatch.tail.count
            + first.eventBytes + (first.events.count - 1)
    }

    func accepts(_ next: EventParts, maxEvents: Int, maxBytes: Int) -> Bool {
        next.entry.endpoint == endpoint
            && next.campaignId == campaignId
            && next.deviceId == deviceId
            && eventCount + next.events.count <= maxEvents
            // One comma before each of the new events.
            && bodyBytes + next.eventBytes + next.events.count <= maxBytes
    }

    mutating func add(_ next: EventParts) {
        parts.append(next)
        eventCount += next.events.count
        bodyBytes += next.eventBytes + next.events.count
    }

    func delivery() -> EventQueue.Delivery {
        let ids = parts.map { $0.entry.id }
        // A lone entry goes exactly as it was queued.
        if parts.count == 1 {
            return EventQueue.Delivery(endpoint: endpoint, body: parts[0].entry.payloadJson, entryIds: ids)
        }
        var body = head
        body.reserveCapacity(bodyBytes)
        var first = true
        for part in parts {
            for event in part.events {
                if !first { body.append(UInt8(ascii: ",")) }
                body.append(event)
                first = false
            }
        }
        body.append(EventBatch.tail)
        return EventQueue.Delivery(endpoint: endpoint, body: body, entryIds: ids)
    }

    private static let tail = Data("]}".utf8)
}
