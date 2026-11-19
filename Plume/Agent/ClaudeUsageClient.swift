import Foundation
import OSLog
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

/// One `get_usage` answer. Windows are 0–1, like the stream's.
nonisolated struct ClaudeUsageReading: Equatable, Sendable {
    var fiveHour: RateLimitInfo.Window?
    var sevenDay: RateLimitInfo.Window?
    var fable: RateLimitInfo.Window?
    var credit: UsageCredit?
}

/// Parses the `rate_limits` object of a `get_usage` reply. The request is
/// experimental, so every field is optional and an unknown shape yields an
/// empty reading, which `ClaudeUsageRequest` treats as a failed poll.
///
/// The shape follows Claude Code 2.1.328: windows (`five_hour`,
/// `seven_day`) carry `utilization` 0–100 and an ISO `resets_at`; `limits[]`
/// rows carry `kind`, `percent` 0–100, `resets_at` and
/// `scope.model.display_name`; `model_scoped[]` rows carry `display_name`
/// and `utilization`. Spend is `spend`, whose `used` and `limit` are
/// `{amount_minor, currency, exponent}`, and `extra_usage`, with
/// `used_credits` and `monthly_limit` in minor units. A bare number in
/// `spend` is read too.
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
        let scoped = root["model_scoped"]?.arrayValue?.compactMap(\.objectValue).first { row in
            row["display_name"]?.stringValue?.localizedCaseInsensitiveContains("fable") == true
        }
        return percentWindow(scoped) ?? percentWindow(root["seven_day_overage_included"]?.objectValue)
    }

    private static func credit(in root: [String: JSONValue]) -> UsageCredit? {
        let extra = root["extra_usage"]?.objectValue
        let spend = root["spend"]?.objectValue
        guard extra != nil || spend != nil else { return nil }
        let credit = UsageCredit(
            usedCents: cents(spend?["used"]) ?? cents(extra?["used_credits"]),
            limitCents: cents(spend?["limit"]) ?? cents(extra?["monthly_limit"]),
            balanceCents: cents(spend?["balance"]),
            isEnabled: spend?["is_enabled"]?.boolValue ?? spend?["enabled"]?.boolValue ?? extra?["is_enabled"]?.boolValue,
            currency: spend?["currency"]?.stringValue
                ?? spend?["used"]?.objectValue?["currency"]?.stringValue
                ?? extra?["currency"]?.stringValue,
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
        let amount = value?.objectValue.map { $0["amount_minor"] } ?? value
        return amount?.doubleValue.flatMap { Int(exactly: $0.rounded()) }
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


nonisolated enum ClaudeUsageFetchResult: Equatable, Sendable {
    case reading(ClaudeUsageReading)
    /// The CLI said the login reports no rate limits (`rate_limits_available:
    /// false`), as for an API key, Bedrock, Vertex, or a login that lacks the
    /// profile scope.
    case unavailable
    case failed
}

/// The CLI's experimental `get_usage` control request, sent to a `claude -p`
/// that is given no user message, so it costs no inference.
/// `docs/headless-protocol.md` has the wire shape.
nonisolated enum ClaudeUsageRequest {
    static let requestID = "usage"

    /// Dropped from the child's environment, so a Plume launched from inside
    /// Claude Code does not pass that session's markers on.
    static let droppedEnvironmentKeys = ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION"]

    /// The CLI writes no transcript without a user
    /// message, but `--no-session-persistence` makes sure, and the user's
    /// hooks and MCP servers have nothing to do in a run that never takes a
    /// turn.
    static let arguments = [
        "claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--settings", #"{"disableAllHooks":true}"#,
    ]

    static let lines = [
        #"{"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}}"#,
        #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"get_usage","skip_behaviors":true}}"#,
    ]

    /// The result a stdout line carries, or nil for any other line.
    static func result(forLine line: String) -> ClaudeUsageFetchResult? {
        guard line.contains("control_response"),
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
              root["type"]?.stringValue == "control_response",
              let response = root["response"]?.objectValue,
              response["request_id"]?.stringValue == requestID
        else { return nil }
        guard response["subtype"]?.stringValue == "success" else {
            let error = response["error"]?.stringValue ?? "no message"
            Log.agent.info("get_usage failed: \(error, privacy: .public)")
            return .failed
        }
        let body = response["response"]?.objectValue
        if body?["rate_limits_available"]?.boolValue == false { return .unavailable }
        guard let rateLimits = body?["rate_limits"]?.objectValue else {
            Log.agent.info("get_usage answered without rate_limits")
            return .failed
        }
        ClaudeUsageClient.logShapeOnce(.object(rateLimits))
        let reading = ClaudeUsageParser.parse(root: rateLimits)
        guard reading != ClaudeUsageReading() else {
            Log.agent.info("get_usage answered with no recognised field")
            return .failed
        }
        return .reading(reading)
    }
}

/// Asks a short-lived `claude -p` for the account's usage, so Plume never
/// handles Claude Code's login itself.
nonisolated struct ClaudeUsageClient: Sendable {
    /// Plume's own, so the run neither reads a project's settings nor runs
    /// in one.
    var workingDirectory: URL
    var timeout: Duration = .seconds(30)

    private static let loggedShape = Mutex(false)

    @concurrent
    func fetch() async -> ClaudeUsageFetchResult {
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let probe = UsageProbe()
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return await withCheckedContinuation { continuation in
            probe.begin(continuation)
            timer = Task { [timeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                Log.agent.info("get_usage timed out")
                probe.finish(.failed)
            }
            let process = AgentProcess(
                label: "claude get_usage",
                onLine: { line in
                    if let result = ClaudeUsageRequest.result(forLine: line) { probe.finish(result) }
                },
                onExit: { status, errorLine in
                    probe.finish(.failed, exit: (status, errorLine))
                }
            )
            do {
                try process.start(
                    arguments: ClaudeUsageRequest.arguments,
                    workingDirectory: workingDirectory.path,
                    environment: LoginShellCommand.plumeEnvironment,
                    removingEnvironment: ClaudeUsageRequest.droppedEnvironmentKeys
                )
            } catch {
                Log.agent.error("get_usage launch failed: \(error.localizedDescription, privacy: .public)")
                probe.finish(.failed)
                return
            }
            probe.adopt(process)
            for line in ClaudeUsageRequest.lines { process.send(line: line) }
        }
    }

    /// The request is experimental; its shape once per launch in the debug
    /// log is what lets the parser be corrected when it moves. Values stay
    /// out: they are the account's spend.
    static func logShapeOnce(_ value: JSONValue) {
        let first = loggedShape.withLock { logged in
            defer { logged = true }
            return !logged
        }
        guard first else { return }
        Log.agent.debug("get_usage answered: \(shape(of: value), privacy: .public)")
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

/// One fetch's reply slot and process. Whichever of the reply, an exit or
/// the timeout comes first answers; the process is ended either way. The
/// process's callbacks hold the probe, so the probe lets go of the process
/// once it is ended.
nonisolated final class UsageProbe: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ClaudeUsageFetchResult, Never>?
        var process: AgentProcess?
        var isFinished = false
    }

    private let state = Mutex(State())

    /// Answers `.failed` at once when the probe already finished, so a
    /// continuation never waits on a reply that came first.
    func begin(_ continuation: CheckedContinuation<ClaudeUsageFetchResult, Never>) {
        let isFinished = state.withLock { state in
            if !state.isFinished { state.continuation = continuation }
            return state.isFinished
        }
        if isFinished { continuation.resume(returning: .failed) }
    }

    /// A reply can land before the process is adopted, which then ends it.
    func adopt(_ process: AgentProcess) {
        let isFinished = state.withLock { state in
            if !state.isFinished { state.process = process }
            return state.isFinished
        }
        if isFinished { Self.end(process) }
    }

    func finish(_ result: ClaudeUsageFetchResult, exit: (Int32, String?)? = nil) {
        let (continuation, process) = state.withLock { state in
            guard !state.isFinished else { return (nil as CheckedContinuation<ClaudeUsageFetchResult, Never>?, nil as AgentProcess?) }
            state.isFinished = true
            defer {
                state.continuation = nil
                state.process = nil
            }
            return (state.continuation, state.process)
        }
        guard let continuation else { return }
        if let (status, errorLine) = exit {
            Log.agent.info("get_usage exited \(status) before replying: \(errorLine ?? "no error", privacy: .public)")
        }
        if let process { Self.end(process) }
        continuation.resume(returning: result)
    }

    /// Off the process's own queue: its callbacks run there, and `terminate`
    /// waits on that queue.
    private static func end(_ process: AgentProcess) {
        DispatchQueue.global(qos: .utility).async { process.terminate() }
    }
}
