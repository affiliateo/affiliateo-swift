import Foundation

/// How the event queue tries again (4.16.2), kept apart from EventQueue.swift
/// so it can be unit tested on any platform.
///
/// A 2xx is sent. A refusal (a 4xx other than 404, 408 and 429) is dropped,
/// with one line in the debug log: the same bytes would be refused again.
/// Everything else stays queued and waits: no answer (offline, a time out),
/// 404, 408, 429 and 5xx. The wait is 5 s, doubling up to 5 minutes, plus up
/// to a quarter more so phones do not all come back at once, and never
/// shorter than the Retry-After a 429 or 503 asks for (up to an hour). Only
/// the queue's size cap drops a waiting event.
///
/// 404 waits on purpose: the server answers it for a device whose first
/// identify has not landed yet ("Call /identify first"), which a later try
/// fixes.
struct SendRetry {
    enum Outcome: Equatable {
        /// A 2xx: the entries leave the queue.
        case sent
        /// Refused: the entries leave the queue, and the debug log says so.
        case refused
        /// The entries stay, and the queue waits before its next try.
        case kept
    }

    static let firstWait: TimeInterval = 5
    static let maxWait: TimeInterval = 300
    static let maxRetryAfter: TimeInterval = 3_600

    /// Kept answers in a row.
    private(set) var failures = 0
    /// No flush sends before this.
    private(set) var nextTry = Date.distantPast
    /// The wait is for the network (no answer came), not one the server asked for.
    private var waitIsNetwork = false

    func canSend(at now: Date) -> Bool {
        now >= nextTry
    }

    /// Takes in one request's answer (`status` nil when none came) and says
    /// what becomes of the entries it carried.
    mutating func answered(status: Int?, retryAfter: String?, at now: Date, jitter: Double) -> Outcome {
        let outcome = SendRetry.outcome(status: status)
        if outcome == .kept {
            failures += 1
            nextTry = now.addingTimeInterval(
                SendRetry.wait(failures: failures, status: status, retryAfter: retryAfter, now: now, jitter: jitter)
            )
            waitIsNetwork = status == nil
        } else {
            failures = 0
            nextTry = .distantPast
            waitIsNetwork = false
        }
        return outcome
    }

    /// The network came back: a wait for it is over. A wait the server asked
    /// for (it answered, busy) still holds.
    mutating func networkBack() {
        guard waitIsNetwork else { return }
        failures = 0
        nextTry = .distantPast
        waitIsNetwork = false
    }

    static func outcome(status: Int?) -> Outcome {
        guard let status else { return .kept }
        if (200..<300).contains(status) { return .sent }
        if (400..<500).contains(status), status != 404, status != 408, status != 429 { return .refused }
        return .kept
    }

    /// The wait after kept answer number `failures` (1 and up): 5 s doubling
    /// up to 5 minutes, at least what a 429 or 503 asked for, plus up to a
    /// quarter more (`jitter` 0 to 1).
    static func wait(failures: Int, status: Int?, retryAfter: String?, now: Date, jitter: Double) -> TimeInterval {
        var base = min(maxWait, firstWait * pow(2, Double(max(1, min(failures, 7)) - 1)))
        if status == 429 || status == 503, let asked = retryAfterSeconds(retryAfter, now: now) {
            base = max(base, asked)
        }
        return base * (1 + 0.25 * max(0, min(jitter, 1)))
    }

    /// A Retry-After header in seconds: whole seconds ("120") or an HTTP date
    /// ("Wed, 21 Oct 2026 07:28:00 GMT", already past is 0), at most an hour.
    /// Nil when it is missing or does not read as either.
    static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval? {
        let text = (header ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let seconds = Double(text) else { return nil }
            return min(seconds, maxRetryAfter)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: text) else { return nil }
        return min(max(date.timeIntervalSince(now), 0), maxRetryAfter)
    }
}
