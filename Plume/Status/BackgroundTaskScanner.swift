import Foundation

/// The launch acknowledgement a background tool writes into its `tool_result`.
///
/// Each tool announces itself in prose with no structured field to read, so
/// the id comes out of the sentence. The table below matches one phrasing per
/// tool rather than one regex over all of them, because the phrasings share
/// nothing and a combined pattern would match the wrong half of a sentence
/// that merely quotes another tool's output.
nonisolated enum BackgroundTaskResult {
    struct Started: Equatable {
        let id: String
        /// How long the tool says it will run, or nil when it says it runs
        /// until something stops it.
        let expiry: Duration?
    }

    private struct Shape {
        let prefix: String
        let parse: (Substring) -> Started?
    }

    private static let shapes: [Shape] = [
        Shape(prefix: "Monitor started (task ") { rest in
            guard let id = token(upTo: ",", in: rest) else { return nil }
            return Started(id: id, expiry: monitorExpiry(in: rest))
        },
        Shape(prefix: "Command running in background with ID: ") { rest in
            guard let id = token(upTo: ".", in: rest) else { return nil }
            return Started(id: id, expiry: nil)
        },
        Shape(prefix: "agentId: ") { rest in
            let id = String(rest.prefix { !$0.isWhitespace })
            return id.isEmpty ? nil : Started(id: id, expiry: nil)
        },
    ]

    static func parse(_ text: String) -> Started? {
        for shape in shapes {
            guard let range = text.range(of: shape.prefix) else { continue }
            if let started = shape.parse(text[range.upperBound...]) { return started }
        }
        return nil
    }

    /// `expires in 25m`, `timeout 1800000ms`, or the word `persistent`, which
    /// declares no end at all.
    private static func monitorExpiry(in rest: Substring) -> Duration? {
        let clause = rest.firstIndex(of: ")").map { rest[..<$0] } ?? rest
        if clause.contains("persistent") { return nil }
        if let range = clause.range(of: "timeout "),
           let milliseconds = number(in: clause[range.upperBound...]) {
            return .milliseconds(Int(milliseconds))
        }
        guard let range = clause.range(of: "expires in ") else { return nil }
        let after = clause[range.upperBound...]
        guard let value = number(in: after) else { return nil }
        let unit = after.drop { $0.isNumber }.prefix { $0.isLetter }
        switch unit {
        case "h": return .seconds(value * 3600)
        case "m": return .seconds(value * 60)
        case "s": return .seconds(value)
        default: return nil
        }
    }

    private static func number(in text: Substring) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The id runs from here to `terminator`, and must not be empty or spill
    /// over a space — the Bash acknowledgement goes on to name an output file
    /// containing the same id, and reading the path instead would pick up a
    /// directory separator.
    private static func token(upTo terminator: Character, in rest: Substring) -> String? {
        let token = rest.prefix { $0 != terminator && !$0.isWhitespace }
        guard !token.isEmpty, rest.dropFirst(token.count).first == terminator else { return nil }
        return String(token)
    }
}

/// Which background tasks a transcript says are still running.
///
/// Both transports write the transcript, so this is the one place that sees
/// them whichever way the tab is driven. It mirrors `SubagentSpawnResults`:
/// one pass over the parent's own bytes, off the main actor.
nonisolated enum BackgroundTaskScanner {
    /// Tools that always run in the background, plus the ones that do only
    /// when asked.
    ///
    /// `Agent` is deliberately absent: a background subagent already keeps
    /// the tab working through `TranscriptStore`'s subagent activity, and
    /// tracking it here too would answer for the same work twice.
    private static let alwaysBackground: [String: BackgroundTaskTracker.Kind] = [
        "Monitor": .monitor,
        "Workflow": .workflow,
    ]
    private static let backgroundWhenAsked: [String: BackgroundTaskTracker.Kind] = [
        "Bash": .backgroundCommand,
    ]

    static func inFlight(parentData: Data, now: Date = Date()) -> [BackgroundTaskTracker.Entry] {
        var kindByToolUseID: [String: BackgroundTaskTracker.Kind] = [:]
        var entries: [String: BackgroundTaskTracker.Entry] = [:]
        let decoder = JSONDecoder()

        for line in parentData.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line))
            else { continue }

            for block in entry.message?.content?.blocks ?? [] {
                switch block {
                case .toolUse(let id, let name, let input):
                    if let kind = alwaysBackground[name] {
                        kindByToolUseID[id] = kind
                    } else if let kind = backgroundWhenAsked[name],
                              input["run_in_background"]?.boolValue == true {
                        kindByToolUseID[id] = kind
                    }
                case .toolResult(let toolUseID, let content, _, _):
                    guard let kind = kindByToolUseID[toolUseID],
                          let content,
                          let started = BackgroundTaskResult.parse(content)
                    else { continue }
                    let startedAt = entry.timestamp ?? now
                    entries[started.id] = BackgroundTaskTracker.Entry(
                        id: started.id,
                        kind: kind,
                        startedAt: startedAt,
                        expiresAt: started.expiry.map { startedAt.addingTimeInterval($0.seconds) }
                    )
                default:
                    continue
                }
            }

            for id in finishedTaskIDs(in: entry) {
                entries.removeValue(forKey: id)
            }
        }

        return entries.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Every task the line reports as no longer running.
    ///
    /// A notification can name several tasks under one status — a session
    /// ending reports all its orphans at once — so the header's ids are read
    /// as a set rather than through `TranscriptTaskNotification`, which
    /// models the single-task case the subagent list needs.
    private static func finishedTaskIDs(in entry: TranscriptEntry) -> [String] {
        var ids: [String] = []
        if let outcome = entry.toolUseResult, let id = outcome.agentID, isTerminal(outcome.status) {
            ids.append(id)
        }
        if let task = entry.attachment?.taskStatus, isTerminal(task.status) {
            ids.append(task.taskID)
        }
        if entry.type == "queue-operation", let content = entry.systemContent {
            ids.append(contentsOf: terminalNotificationTaskIDs(in: content))
        }
        return ids
    }

    /// A Monitor event notification carries no `<status>` and must clear
    /// nothing — only the monitor's closing notice does.
    private static func terminalNotificationTaskIDs(in content: String) -> [String] {
        guard let start = content.range(of: "<task-notification>") else { return [] }
        let rest = content[start.upperBound...]
        let header = rest.range(of: "<result>").map { rest[..<$0.lowerBound] } ?? rest
        guard let status = tagValue("status", in: header), isTerminal(status) else { return [] }
        return tagValues("task-id", in: header)
    }

    private static func isTerminal(_ status: String?) -> Bool {
        switch status {
        case "completed", "failed", "error", "killed", "stopped": true
        default: false
        }
    }

    private static func tagValue(_ tag: String, in header: Substring) -> String? {
        tagValues(tag, in: header).first
    }

    private static func tagValues(_ tag: String, in header: Substring) -> [String] {
        var values: [String] = []
        var cursor = header.startIndex
        while let open = header.range(of: "<\(tag)>", range: cursor..<header.endIndex),
              let close = header.range(of: "</\(tag)>", range: open.upperBound..<header.endIndex) {
            let value = header[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values.append(value) }
            cursor = close.upperBound
        }
        return values
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
