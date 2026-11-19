import Foundation
import OSLog
import Security
import Synchronization

/// Usage credit (extra usage) spend for the billing period, in minor units of
/// `currency` (cents for USD).
nonisolated struct UsageCredit: Equatable, Codable, Sendable {
    var usedCents: Int?
    var limitCents: Int?
    var balanceCents: Int?
    var isEnabled: Bool?
    var currency: String?
    /// When the billing period resets, from the active `spend` row of
    /// `limits[]`.
    var resetsAt: Date?

    var remainingCents: Int? {
        if let balanceCents { return balanceCents }
        guard let limitCents, let usedCents else { return nil }
        return max(limitCents - usedCents, 0)
    }
}

/// One answer from the usage endpoint. Windows are 0–1, like the stream's.
nonisolated struct ClaudeUsageReading: Equatable, Sendable {
    var fiveHour: RateLimitInfo.Window?
    var sevenDay: RateLimitInfo.Window?
    var fable: RateLimitInfo.Window?
    var credit: UsageCredit?
}

/// Parses `GET /api/oauth/usage`. The endpoint is undocumented, so every
/// field is optional and an unknown shape yields an empty reading rather
/// than an error.
///
/// The shape follows Claude Code 2.1.328's own schema for it: top-level
/// windows (`five_hour`, `seven_day`) carry `utilization` 0–100 and an ISO
/// `resets_at`; `limits[]` rows carry `kind`, `percent` 0–100, `resets_at`
/// and `scope.model.display_name`; spend is `extra_usage` with
/// `used_credits` and `monthly_limit`. A `spend` object with `used`, `limit`
/// and `balance` is also read, since some accounts have been reported to
/// receive that form.
nonisolated enum ClaudeUsageParser {
    static func parse(_ data: Data) -> ClaudeUsageReading? {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return parse(root: root)
    }

    static func parse(root: [String: JSONValue]) -> ClaudeUsageReading {
        ClaudeUsageReading(
            fiveHour: percentWindow(root["five_hour"]?.objectValue),
            sevenDay: percentWindow(root["seven_day"]?.objectValue),
            fable: fableWindow(in: root),
            credit: credit(in: root)
        )
    }

    private static func fableWindow(in root: [String: JSONValue]) -> RateLimitInfo.Window? {
        let rows = root["limits"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let row = rows.first { row in
            guard row["kind"]?.stringValue == "weekly_scoped" else { return false }
            let name = row["scope"]?.objectValue?["model"]?.objectValue?["display_name"]?.stringValue
            return name?.localizedCaseInsensitiveContains("fable") == true
        }
        if let row, let percent = row["percent"]?.doubleValue ?? row["utilization"]?.doubleValue {
            return RateLimitInfo.Window(utilization: percent / 100, resetsAt: date(row["resets_at"]))
        }
        return percentWindow(root["seven_day_overage_included"]?.objectValue)
    }

    private static func credit(in root: [String: JSONValue]) -> UsageCredit? {
        let extra = root["extra_usage"]?.objectValue
        let spend = root["spend"]?.objectValue
        guard extra != nil || spend != nil else { return nil }
        let credit = UsageCredit(
            usedCents: cents(spend?["used"]) ?? cents(extra?["used_credits"]),
            limitCents: cents(spend?["limit"]) ?? cents(extra?["monthly_limit"]),
            balanceCents: cents(spend?["balance"]),
            isEnabled: spend?["is_enabled"]?.boolValue ?? extra?["is_enabled"]?.boolValue,
            currency: spend?["currency"]?.stringValue ?? extra?["currency"]?.stringValue,
            resetsAt: creditReset(in: root)
        )
        return credit == UsageCredit() ? nil : credit
    }

    private static func creditReset(in root: [String: JSONValue]) -> Date? {
        let rows = root["limits"]?.arrayValue?.compactMap(\.objectValue).filter { $0["kind"]?.stringValue == "spend" } ?? []
        let row = rows.first { $0["is_active"]?.boolValue == true } ?? rows.first
        return date(row?["resets_at"])
    }

    private static func percentWindow(_ object: [String: JSONValue]?) -> RateLimitInfo.Window? {
        guard let object, let percent = object["utilization"]?.doubleValue else { return nil }
        return RateLimitInfo.Window(utilization: percent / 100, resetsAt: date(object["resets_at"]))
    }

    private static func cents(_ value: JSONValue?) -> Int? {
        value?.doubleValue.map { Int($0.rounded()) }
    }

    private static func date(_ value: JSONValue?) -> Date? {
        if let seconds = value?.doubleValue { return Date(timeIntervalSince1970: seconds) }
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Claude Code's OAuth login, read from its Keychain item. Read-only: the
/// refresh token is single-use, so refreshing here would race the CLI and
/// log it out.
nonisolated enum ClaudeCredentials {
    static let service = "Claude Code-credentials"

    enum Read: Equatable {
        case token(String, expiresAt: Date?)
        case missing
        case denied
    }

    /// Asks for attributes only, which never prompts.
    static func exist() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> Read {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return read(status: status, data: result as? Data)
    }

    static func read(status: OSStatus, data: Data?) -> Read {
        switch status {
        case errSecSuccess:
            guard let data, let token = parse(data) else { return .missing }
            return token
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        default:
            // A locked Keychain among them, which a later poll can get past.
            return .missing
        }
    }

    static func parse(_ data: Data) -> Read? {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let oauth = root["claudeAiOauth"]?.objectValue,
              let token = oauth["accessToken"]?.stringValue, !token.isEmpty
        else { return nil }
        let expiresAt = oauth["expiresAt"]?.doubleValue.map { value in
            // Claude Code writes milliseconds; anything this small is seconds.
            Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
        }
        return .token(token, expiresAt: expiresAt)
    }
}

nonisolated enum ClaudeUsageFetchResult: Equatable, Sendable {
    case reading(ClaudeUsageReading)
    case rateLimited(retryAfter: TimeInterval?)
    /// No credentials, an expired token, or a 401: wait for the CLI to
    /// refresh the token, and keep the last reading meanwhile.
    case unauthorized
    /// The Keychain refused the read, which means the user declined access.
    case credentialsDenied
    case failed
}

nonisolated struct ClaudeUsageClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    var session: URLSession = .shared
    var readCredentials: @Sendable () -> ClaudeCredentials.Read = {
        ClaudeCredentials.exist() ? ClaudeCredentials.read() : .missing
    }

    private static let loggedShape = Mutex(false)

    @concurrent
    func fetch(now: Date = Date()) async -> ClaudeUsageFetchResult {
        let token: String
        switch readCredentials() {
        case .missing: return .unauthorized
        case .denied: return .credentialsDenied
        case .token(let value, let expiresAt):
            if let expiresAt, expiresAt <= now { return .unauthorized }
            token = value
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed }

        switch http.statusCode {
        case 200..<300:
            logShapeOnce(data)
            return ClaudeUsageParser.parse(data).map { .reading($0) } ?? .failed
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now))
        default:
            return .failed
        }
    }

    /// Seconds, or an HTTP date.
    static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max($0.timeIntervalSince(now), 0) }
    }

    /// The endpoint is undocumented; one body per launch in the debug log is
    /// what lets the parser be corrected when the shape moves.
    private func logShapeOnce(_ data: Data) {
        let first = Self.loggedShape.withLock { logged in
            defer { logged = true }
            return !logged
        }
        guard first else { return }
        let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        Log.agent.debug("Claude usage endpoint answered: \(body, privacy: .public)")
    }
}
