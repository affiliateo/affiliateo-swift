import Foundation

/// What `Affiliateo.freeAccess()` answered (4.12.0): whether the app owner
/// gave the signed-in person free access from their Affiliateo dashboard.
///
/// ```swift
/// let access = await Affiliateo.freeAccess()
/// if access.active { unlock(access.productId) }
/// ```
public struct AffiliateoFreeAccess: Equatable {
    /// Unlock the app when true.
    public let active: Bool
    /// The store product id of the plan the owner chose. nil means full
    /// access (every paid feature).
    public let productId: String?
    /// When the free access ends. nil means it has no end date.
    public let expiresAt: Date?

    public init(active: Bool, productId: String? = nil, expiresAt: Date? = nil) {
        self.active = active
        self.productId = productId
        self.expiresAt = expiresAt
    }

    /// No free access.
    public static let inactive = AffiliateoFreeAccess(active: false)
}

/// The last answer the server gave, kept on the phone so an app opened
/// offline still unlocks for a while (4.12.0). Cleared on sign-out and when a
/// different user signs in, since it belongs to the person who was asked about.
enum FreeAccessCache {
    static let key = "affiliateo_free_access"
    /// How long a saved answer counts without a new one from the server.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// A saved answer dated further ahead than this is not trusted, so a clock
    /// set back cannot stretch the 7 days.
    static let clockSkew: TimeInterval = 5 * 60

    struct Entry: Codable, Equatable {
        let active: Bool
        let productId: String?
        /// Milliseconds since 1970, nil for no end.
        let expiresAt: Double?
        /// When the server gave this answer, milliseconds since 1970.
        let checkedAt: Double

        enum CodingKeys: String, CodingKey {
            case active
            case productId = "product_id"
            case expiresAt = "expires_at"
            case checkedAt = "checked_at"
        }

        init(_ answer: AffiliateoFreeAccess, checkedAt: Date) {
            self.active = answer.active
            self.productId = answer.productId
            self.expiresAt = answer.expiresAt.map { $0.timeIntervalSince1970 * 1000 }
            self.checkedAt = checkedAt.timeIntervalSince1970 * 1000
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> Entry? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// The answer when the server could not be asked: the saved one while it
    /// is still good (its end, if any, is in the future and the server gave
    /// it at most 7 days ago), otherwise no free access.
    static func offlineAnswer(_ entry: Entry?, now: Date) -> AffiliateoFreeAccess {
        guard let entry, entry.active else { return .inactive }
        let age = now.timeIntervalSince1970 - entry.checkedAt / 1000
        guard age <= maxAge, age >= -clockSkew else { return .inactive }
        let expiresAt = entry.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let expiresAt, expiresAt <= now { return .inactive }
        return AffiliateoFreeAccess(active: true, productId: entry.productId, expiresAt: expiresAt)
    }

    /// The server's reply `{ active, product_id, expires_at }`, or nil when
    /// it is not one (the check then counts as failed).
    static func parseReply(_ data: Data) -> AffiliateoFreeAccess? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let active = json["active"] as? Bool else { return nil }
        guard active else { return .inactive }
        let product = (json["product_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var expiresAt: Date?
        if let raw = json["expires_at"], !(raw is NSNull) {
            // An end the SDK cannot read must not turn into "no end".
            guard let text = raw as? String, let date = parseDate(text) else { return nil }
            expiresAt = date
        }
        return AffiliateoFreeAccess(
            active: true,
            productId: product?.isEmpty == false ? product : nil,
            expiresAt: expiresAt
        )
    }

    /// ISO 8601 with or without fractional seconds ("2026-11-17T12:00:00.000Z",
    /// "2026-11-17T12:00:00+00:00").
    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
