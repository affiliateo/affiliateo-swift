import Foundation

/// Device information sent during identification.
public struct DeviceInfo {
    public let deviceModel: String
    public let os: String
    public let osVersion: String
    public let appVersion: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let timezone: String
    public let language: String
}

/// Response from the identify endpoint.
public struct IdentifyResponse: Decodable {
    public let visitorId: String
    public let refCode: String?
    public let matched: Bool

    enum CodingKeys: String, CodingKey {
        case visitorId = "visitor_id"
        case refCode = "ref_code"
        case matched
    }
}

/// Event types that can be sent to the API.
public enum EventType: String {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case screenView = "screen_view"
    case custom = "custom"
}

/// A single event to send to the API.
///
/// `screen` is set for `screen_view` events (e.g. "Paywall"). `metadata` is an
/// optional dictionary of additional context (e.g. `["plan": "pro"]`).
public struct MobileEvent {
    public let type: EventType
    public let timestamp: String
    public let screen: String?
    public let metadata: [String: Any]?
    /// Dedup key, so the server can drop a replay of this exact event.
    ///
    /// Stamped here in `init` for the same reason `timestamp` is: a failed
    /// send is queued and retried on the next launch, and the value has to
    /// describe when the event HAPPENED rather than when it finally landed.
    /// The id follows that guarantee — every retry of one event carries the
    /// same id, so the server keeps exactly one row for it.
    ///
    /// Without it, a request that reaches the server and is written but whose
    /// response is lost on a flaky connection gets resent and counted twice.
    /// For a `custom` event that is a duplicated funnel conversion.
    public let eventId: String

    public init(type: EventType, screen: String? = nil, metadata: [String: Any]? = nil) {
        self.type = type
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.screen = screen
        self.metadata = metadata
        // Lowercased to match the other SDKs; Foundation returns uppercase.
        self.eventId = UUID().uuidString.lowercased()
    }
}

/// Errors thrown by the SDK.
public enum AffiliateoError: Error, LocalizedError {
    case identifyFailed
    case eventSendFailed
    case appleTokenRegisterFailed

    public var errorDescription: String? {
        switch self {
        case .identifyFailed: return "Failed to identify device with Affiliateo."
        case .eventSendFailed: return "Failed to send events to Affiliateo."
        case .appleTokenRegisterFailed: return "Failed to register Apple appAccountToken with Affiliateo."
        }
    }
}

/// The current attribution state.
public struct AffiliateoState {
    public let refCode: String?
    public let isMatched: Bool
    public let isLoading: Bool
    public let visitorId: String?
    /// StoreKit 2 appAccountToken UUID. Pass this to your StoreKit 2 purchase
    /// call so Apple stamps it onto the transaction and our webhook can
    /// resolve it back to the affiliate.
    ///
    /// ```swift
    /// let token = affiliateo.state.appAccountToken
    /// let opts: Set<Product.PurchaseOption> = token.map { [.appAccountToken($0)] } ?? []
    /// let result = try await product.purchase(options: opts)
    /// ```
    ///
    /// Nil before identify completes, when the device isn't matched to any
    /// affiliate, or on platforms other than iOS / macCatalyst.
    public let appAccountToken: UUID?

    public init(
        refCode: String?,
        isMatched: Bool,
        isLoading: Bool,
        visitorId: String?,
        appAccountToken: UUID? = nil
    ) {
        self.refCode = refCode
        self.isMatched = isMatched
        self.isLoading = isLoading
        self.visitorId = visitorId
        self.appAccountToken = appAccountToken
    }
}
