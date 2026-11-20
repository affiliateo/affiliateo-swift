import Foundation

/// What `setAffiliateCode` answers (4.18.0).
///
/// An affiliate code is a coupon code without the coupon. The buyer types an
/// affiliate's code in a box YOUR app shows, you hand it to the SDK, and that
/// affiliate gets the sale. No discount, the App Store is not involved, and
/// nothing is matched by IP address for that buyer. The code is the one each
/// affiliate already has: the end of their link.
///
/// ```swift
/// let result = await Affiliateo.setAffiliateCode(codeField.text)
/// if result.matched {
///     // Say "Code applied".
/// } else {
///     // Say "Code not found". result.reason says why.
/// }
/// // Then buy as you already do, with affiliateo.state.appAccountToken.
/// ```
public struct AffiliateoAffiliateCode: Equatable {
    /// The code is an affiliate's, and it is on this device now.
    public let matched: Bool
    /// The affiliate's code as Affiliateo keeps it. nil unless `matched`.
    public let refCode: String?
    /// Why it did not match. nil when it did.
    public let reason: Reason?

    public enum Reason: String, Equatable {
        /// No affiliate of this app has that code. Nothing changed.
        case notFound
        /// Nothing was typed, or it is not one word of at most 64 characters.
        case invalid
        /// The app's owner has affiliate codes switched off in Affiliateo.
        case off
        /// The SDK has not reached Affiliateo for this device yet (or the
        /// person opted out), so there is nothing to put the code on. Try
        /// again in a moment.
        case notReady
        /// Offline, too many tries, or the server did not answer. Try again.
        case failed
    }

    public init(matched: Bool, refCode: String?, reason: Reason?) {
        self.matched = matched
        self.refCode = refCode
        self.reason = reason
    }

    static func applied(_ refCode: String) -> AffiliateoAffiliateCode {
        AffiliateoAffiliateCode(matched: true, refCode: refCode, reason: nil)
    }

    static func refused(_ reason: Reason) -> AffiliateoAffiliateCode {
        AffiliateoAffiliateCode(matched: false, refCode: nil, reason: reason)
    }
}

/// The rules of a typed code, kept pure so they are tested without a server.
enum AffiliateCodeRules {
    /// The longest code the server reads.
    static let maxLength = 64

    /// What the buyer typed, ready to send: the space around it and a leading
    /// "@" dropped, or nil when there is nothing usable (empty, more than one
    /// word, too long). The server applies the same rule.
    static func normalize(_ raw: String) -> String? {
        var code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while code.hasPrefix("@") { code.removeFirst() }
        code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count <= maxLength else { return nil }
        guard code.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              code.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return code
    }

    /// The server's answer as the app reads it. POST
    /// /api/v1/mobile/affiliate-code answers 200 with `matched` (and the
    /// `ref_code` when true), 403 `affiliate_codes_off` while the owner's
    /// switch is off, 404 `unknown_device` before identify has run, 400
    /// `invalid_code`, and anything else is a failure worth a retry.
    static func parseReply(status: Int, data: Data) -> AffiliateoAffiliateCode {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = json["code"] as? String
        switch status {
        case 200...299:
            guard let matched = json["matched"] as? Bool else { return .refused(.failed) }
            if matched, let refCode = json["ref_code"] as? String, !refCode.isEmpty {
                return .applied(refCode)
            }
            return .refused(matched ? .failed : .notFound)
        case 403 where code == "affiliate_codes_off":
            return .refused(.off)
        case 404 where code == "unknown_device":
            return .refused(.notReady)
        case 400 where code == "invalid_code":
            return .refused(.invalid)
        default:
            return .refused(.failed)
        }
    }
}
