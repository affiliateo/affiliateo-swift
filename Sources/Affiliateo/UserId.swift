import Foundation

/// Which user ids may name a signed-in person (4.11.0).
///
/// Every device that signs in with the same user id becomes ONE customer of
/// the app on Affiliateo's side, so an id that really means "nobody" ("null",
/// "undefined", "guest", "0") would merge every stranger whose app sent it
/// into one person. The server refuses these with a 400; this is the same
/// list, checked here so a wrong call is skipped (and says so with
/// `debug: true`) instead of costing a request.
///
/// KEEP IN SYNC with src/lib/customers/user-id.ts in the Affiliateo web repo
/// and with the copies in the other SDKs.
enum AffiliateoUserId {
    static let maxLength = 128

    private static let notAUser: Set<String> = [
        "null", "(null)", "<null>", "nil", "none", "no", "undefined", "unidentified",
        "unknown", "anonymous", "anon", "guest", "nan", "false", "true",
        "0", "-1", "[]", "{}", "[object object]",
    ]

    /// The trimmed id when it can name a person, otherwise nil. Length is
    /// counted the way the server counts it (UTF-16 code units).
    static func usable(_ value: String?) -> String? {
        guard let value else { return nil }
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf16.count <= maxLength else { return nil }
        if notAUser.contains(id.lowercased()) { return nil }
        // RevenueCat's own anonymous id names an install, not a user.
        if id.hasPrefix("$RCAnonymousID:") { return nil }
        return id
    }
}
