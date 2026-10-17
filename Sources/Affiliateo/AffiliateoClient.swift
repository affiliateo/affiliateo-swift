import Foundation

/// HTTP client for communicating with the Affiliateo API.
final class AffiliateoClient {
    private let apiUrl: String

    init(apiUrl: String = "https://affiliateo.com") {
        self.apiUrl = apiUrl.hasSuffix("/") ? String(apiUrl.dropLast()) : apiUrl
    }

    /// Identify this device to the Affiliateo API and get attribution info.
    func identify(campaignId: String, deviceId: String, deviceInfo: DeviceInfo, adIdentifiers: AdIdentifiers) async throws -> IdentifyResponse {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/identify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "device_model": deviceInfo.deviceModel,
            "os": deviceInfo.os,
            "os_version": deviceInfo.osVersion,
            "app_version": deviceInfo.appVersion,
            "screen_width": deviceInfo.screenWidth,
            "screen_height": deviceInfo.screenHeight,
            "timezone": deviceInfo.timezone,
            "language": deviceInfo.language,
        ]
        // Advertising ids (4.9.0): only what the person allowed, see AdIdentifiers.
        for (key, value) in adIdentifiers.payload { body[key] = value }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AffiliateoError.identifyFailed
        }

        let result = try JSONDecoder().decode(IdentifyResponse.self, from: data)
        return result
    }

    /// Send a batch of session events (session_start, session_end).
    func sendEvents(campaignId: String, deviceId: String, events: [MobileEvent]) async throws {
        if events.isEmpty { return }

        let url = URL(string: "\(apiUrl)/api/v1/mobile/event")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let eventsArray: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "type": event.type.rawValue,
                "timestamp": event.timestamp,
                // Stable across retries — see MobileEvent.eventId.
                "event_id": event.eventId,
            ]
            if let screen = event.screen { dict["screen"] = screen }
            if let metadata = event.metadata { dict["metadata"] = metadata }
            return dict
        }

        let body: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "events": eventsArray,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AffiliateoError.eventSendFailed
        }
    }

    /// Tell Affiliateo who is signed in on this device: the user id, and since
    /// 4.12.0 the SHA-256 of their email when the app gave one (never the
    /// address itself), which is what free access is matched on.
    ///
    /// Since 4.11.0 the answer is read rather than ignored:
    /// - `.linked(outcome:)`: the server has it. The outcome says what
    ///   happened to the app's customer: "same", "adopted", "merged", or
    ///   "switched" (a different person signed in on this device).
    /// - `.notLinked`: the device is not known yet, because the sign-in
    ///   raced ahead of this launch's first identify. Sent again once that
    ///   call has finished.
    /// - `.refused`: a 400, the id is not one a sign-in gives. Not retried.
    /// Anything else (offline, a 5xx, a rate limit) throws, and the next
    /// launch sends the stored id again.
    func identifyUser(campaignId: String, deviceId: String, userId: String, emailSha256: String? = nil) async throws -> IdentifyUserResult {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/identify-user")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "user_id": userId,
        ]
        // Left out when there is no email: the server keeps what it has.
        if let emailSha256 { body["email_sha256"] = emailSha256 }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AffiliateoError.identifyFailed
        }
        if httpResponse.statusCode == 400 { return .refused }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AffiliateoError.identifyFailed
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let linked = json?["linked"] as? Bool, !linked { return .notLinked }
        return .linked(outcome: json?["outcome"] as? String)
    }

    /// The person signed out (4.11.0). POST /api/v1/mobile/logout: the
    /// device keeps its device id and visitor id, and from now on counts as
    /// a new anonymous customer of the app. Returns the server's outcome
    /// ("signed_out" or "already_anonymous"); throws when it did not land.
    func logout(campaignId: String, deviceId: String) async throws -> String? {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/logout")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "campaign_id": campaignId,
            "device_id": deviceId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AffiliateoLogoutFailed()
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["outcome"] as? String
    }

    /// Whether the app owner gave the person signed in on this device free
    /// access (4.12.0). POST /api/v1/mobile/free-access. Throws when there is
    /// no usable answer (offline, a non-2xx, a reply that is not one), so the
    /// caller can fall back to the saved answer.
    func freeAccess(campaignId: String, deviceId: String) async throws -> AffiliateoFreeAccess {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/free-access")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An app may hold its paywall for this answer, so it does not wait
        // the default minute: past this the saved answer is used.
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "campaign_id": campaignId,
            "device_id": deviceId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let answer = FreeAccessCache.parseReply(data) else {
            throw AffiliateoFreeAccessCheckFailed()
        }
        return answer
    }

    /// Report the host app's RevenueCat App User ID
    /// (`Purchases.shared.appUserID`).
    ///
    /// Lets an app owner grant this affiliate complimentary access to the app
    /// from their Affiliateo dashboard. Without it, Affiliateo can only match
    /// an affiliate to a RevenueCat customer by email, which requires the host
    /// app to be setting RevenueCat's `$email` attribute AND the affiliate to
    /// have used the same address they used on Affiliateo.
    ///
    /// Deliberately separate from `identifyUser`: sign-in and RevenueCat
    /// configuration happen at different moments, and an app may do one
    /// without the other. The server accepts either field alone and writes
    /// only what the request carried, so neither wipes the other.
    ///
    /// Write-once per device server-side. Re-sending the same id every launch
    /// is a no-op; a DIFFERENT id for an already-bound device is rejected, so
    /// a tampered client cannot repoint an established device at somebody
    /// else's RevenueCat customer.
    func identifyRevenueCatUser(campaignId: String, deviceId: String, revenueCatUserId: String) async throws {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/identify-user")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "campaign_id": campaignId,
            "device_id": deviceId,
            "revenuecat_user_id": revenueCatUserId,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AffiliateoError.identifyFailed
        }
    }

    // registerAppleToken (POST /api/v1/mobile/apple-token) used to live here.
    // Since 4.10.0 the appAccountToken IS the visitor id, which the server
    // already knows from identify, so there is nothing left to register.

    /// Send Apple's AdServices attribution token to the backend, which
    /// redeems it with Apple and stamps whether this install came from an
    /// Apple Search Ads tap (and which campaign / ad group / keyword).
    /// Fired once per install for EVERY install — most paid installs have
    /// no affiliate, and "not from an ad" is itself the answer that turns
    /// organic into a real number.
    func registerAppleAdsToken(campaignId: String, visitorId: String, token: String) async throws {
        let url = URL(string: "\(apiUrl)/api/v1/mobile/apple-ads-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "campaign_id": campaignId,
            "visitor_id": visitorId,
            "token": token,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        // 200 (already attributed) and 202 (accepted, redeeming in the
        // background) both mean the token landed.
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
            throw AffiliateoError.appleTokenRegisterFailed
        }
    }
}
