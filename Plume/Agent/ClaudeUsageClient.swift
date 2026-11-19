import CryptoKit
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
        value?.doubleValue.flatMap { Int(exactly: $0.rounded()) }
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
///
/// The CLI names the item `Claude Code-credentials`, plus `-` and the first 8
/// hex digits of the SHA-256 of its config directory when
/// `CLAUDE_CONFIG_DIR` (or `CLAUDE_SECURESTORAGE_CONFIG_DIR`) is set, under
/// the account `$USER`. Each config directory a user has signed in from
/// leaves its own item.
nonisolated enum ClaudeCredentials {
    static let servicePrefix = "Claude Code-credentials"

    enum Read: Equatable {
        case token(String, expiresAt: Date?)
        case missing
        case denied
    }

    struct Item: Equatable {
        let service: String
        let account: String
        let modifiedAt: Date?
    }

    /// The item a config directory set in Plume's own environment names, or
    /// nil with none set.
    static func configuredServiceName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let configDir: String?
        if let secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            configDir = secure.isEmpty ? nil : secure
        } else if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configDir = dir
        } else {
            configDir = nil
        }
        guard let configDir else {
            return environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] != nil ? servicePrefix : nil
        }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(servicePrefix)-\(hex.prefix(8))"
    }

    static func accountName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } && !name.isEmpty
            ? name
            : "claude-code-user"
    }

    /// The item Plume's own environment names, else the most recently
    /// written one. The CLI rewrites its item on every token refresh, so the
    /// newest tracks the login in use; a `CLAUDE_CONFIG_DIR` set only in a
    /// shell never reaches an app opened from Finder. Reading an item's
    /// contents is what prompts, so only the chosen one is read.
    static func choose(from items: [Item], configuredService: String?, account: String) -> Item? {
        let mine = items.filter { $0.account == account && $0.service.hasPrefix(servicePrefix) }
        if let configuredService, let exact = mine.first(where: { $0.service == configuredService }) { return exact }
        return mine.max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// Attributes only, which never prompts.
    static func items() -> [Item] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(servicePrefix) else { return nil }
            return Item(
                service: service,
                account: row[kSecAttrAccount as String] as? String ?? "",
                modifiedAt: row[kSecAttrModificationDate as String] as? Date
            )
        }
    }

    static func read() -> Read {
        guard let item = choose(from: items(), configuredService: configuredServiceName(), account: accountName()) else { return .missing }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
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
    var readCredentials: @Sendable () -> ClaudeCredentials.Read = { ClaudeCredentials.read() }

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

    /// The endpoint is undocumented; its shape once per launch in the debug
    /// log is what lets the parser be corrected when it moves. Values stay
    /// out: they are the account's spend.
    private func logShapeOnce(_ data: Data) {
        let first = Self.loggedShape.withLock { logged in
            defer { logged = true }
            return !logged
        }
        guard first else { return }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let shape = Self.shape(of: root)
        Log.agent.debug("Claude usage endpoint answered: \(shape, privacy: .public)")
    }

    /// Keys and value types, with an array shown as the union of its
    /// elements' shapes.
    static func shape(of value: JSONValue) -> String {
        switch value {
        case .string: return "string"
        case .number: return "number"
        case .bool: return "bool"
        case .null: return "null"
        case .object(let object):
            let fields = object.keys.sorted().map { "\($0):\(shape(of: object[$0]!))" }
            return "{\(fields.joined(separator: ","))}"
        case .array(let elements):
            var seen: [String] = []
            for element in elements {
                let item = shape(of: element)
                if !seen.contains(item) { seen.append(item) }
            }
            return "[\(seen.joined(separator: "|"))]"
        }
    }
}
