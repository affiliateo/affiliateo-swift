import Foundation
import CryptoKit

/// The signed-in person's email as Affiliateo receives it (4.12.0): the
/// SHA-256 of the trimmed, lowercased address, in lowercase hex. The address
/// itself never leaves the phone. Affiliateo hashes the address an app owner
/// types for free access the same way and compares the two.
///
/// KEEP IN SYNC with the server and with the copies in the other SDKs.
enum AffiliateoEmail {
    /// The hash, or nil when there is no address (nil, empty or only spaces).
    static func sha256Hex(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
