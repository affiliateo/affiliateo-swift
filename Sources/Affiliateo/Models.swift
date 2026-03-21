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
}

/// A single event to send to the API.
public struct MobileEvent {
    public let type: EventType
    public let timestamp: String

    public init(type: EventType) {
        self.type = type
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
}

/// Errors thrown by the SDK.
public enum AffiliateoError: Error, LocalizedError {
    case identifyFailed
    case eventSendFailed

    public var errorDescription: String? {
        switch self {
        case .identifyFailed: return "Failed to identify device with Affiliateo."
        case .eventSendFailed: return "Failed to send events to Affiliateo."
        }
    }
}

/// The current attribution state.
public struct AffiliateoState {
    public let refCode: String?
    public let isMatched: Bool
    public let isLoading: Bool
    public let visitorId: String?
}
