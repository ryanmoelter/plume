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
        /// What the tool says the task is for. Only the async-agent
        /// acknowledgement names one; Monitor and Bash announce the id alone,
        /// so for those the scanner reads the call's own `description`.
        let description: String?

        init(id: String, expiry: Duration?, description: String? = nil) {
            self.id = id
            self.expiry = expiry
            self.description = description
        }
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
            return id.isEmpty ? nil : Started(id: id, expiry: nil, description: parenthetical(in: rest))
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

    /// The async-agent acknowledgement follows the id with the agent's task
    /// in parentheses. A build that instead explains the id there says so in
    /// a sentence, which no reader wants as a title.
    private static func parenthetical(in rest: Substring) -> String? {
        guard let open = rest.firstIndex(of: "("),
              let close = rest[open...].firstIndex(of: ")")
        else { return nil }
        let text = rest[rest.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("internal ID") else { return nil }
        return text
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

    /// What the tool call said it was for, and which tool it was.
    ///
    /// The launch acknowledgement names no description for either Monitor or
    /// a backgrounded Bash, so the only place it exists is the call's own
    /// `description` argument — read here and carried to the entry.
    private struct Launch {
        let kind: BackgroundTaskTracker.Kind
        let description: String?
        /// A monitor asked to persist watches for as long as it is allowed.
        /// One that was not stops at its first event, which is the only
        /// notice some of them ever write.
        let stopsAtFirstEvent: Bool
    }

    static func inFlight(parentData: Data, now: Date = Date()) -> [BackgroundTaskTracker.Entry] {
        var launchByToolUseID: [String: Launch] = [:]
        var entries: [String: BackgroundTaskTracker.Entry] = [:]
        var stopsAtFirstEvent: Set<String> = []
        let decoder = JSONDecoder()

        for line in parentData.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line))
            else { continue }

            for block in entry.message?.content?.blocks ?? [] {
                switch block {
                case .toolUse(let id, let name, let input):
                    let description = describedPurpose(in: input)
                    // Only an explicit `false` settles this. The argument is
                    // absent from a sixth of real Monitor calls, and reading
                    // that as one-shot would retire a monitor still watching
                    // — letting the Mac sleep mid-work, the costlier mistake.
                    let oneShot = name == "Monitor" && input["persistent"]?.boolValue == false
                    if let kind = alwaysBackground[name] {
                        launchByToolUseID[id] = Launch(
                            kind: kind,
                            description: description,
                            stopsAtFirstEvent: oneShot
                        )
                    } else if let kind = backgroundWhenAsked[name],
                              input["run_in_background"]?.boolValue == true {
                        launchByToolUseID[id] = Launch(
                            kind: kind,
                            description: description,
                            stopsAtFirstEvent: false
                        )
                    }
                case .toolResult(let toolUseID, let content, _, _):
                    guard let launch = launchByToolUseID[toolUseID],
                          let content,
                          let started = BackgroundTaskResult.parse(content)
                    else { continue }
                    let startedAt = entry.timestamp ?? now
                    entries[started.id] = BackgroundTaskTracker.Entry(
                        id: started.id,
                        kind: launch.kind,
                        description: started.description ?? launch.description,
                        startedAt: startedAt,
                        expiresAt: started.expiry.map { startedAt.addingTimeInterval($0.seconds) }
                    )
                    // Only a persistent monitor declares no end, so an
                    // announcement naming none overrides the call's argument.
                    if launch.stopsAtFirstEvent, started.expiry != nil {
                        stopsAtFirstEvent.insert(started.id)
                    }
                default:
                    continue
                }
            }

            for id in finishedTaskIDs(in: entry, stoppingAtFirstEvent: stopsAtFirstEvent) {
                entries.removeValue(forKey: id)
                stopsAtFirstEvent.remove(id)
            }
        }

        return entries.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// A Monitor and a backgrounded Bash both take a `description`; a
    /// Workflow names itself through `workflow_name` instead.
    private static func describedPurpose(in input: [String: JSONValue]) -> String? {
        for key in ["description", "workflow_name"] {
            let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// Every task the line reports as no longer running.
    ///
    /// A notification can name several tasks under one status — a session
    /// ending reports all its orphans at once — so the header's ids are read
    /// as a set rather than through `TranscriptTaskNotification`, which
    /// models the single-task case the subagent list needs.
    private static func finishedTaskIDs(
        in entry: TranscriptEntry,
        stoppingAtFirstEvent: Set<String>
    ) -> [String] {
        var ids: [String] = []
        if let outcome = entry.toolUseResult, let id = outcome.agentID, isTerminal(outcome.status) {
            ids.append(id)
        }
        if let task = entry.attachment?.taskStatus, isTerminal(task.status) {
            ids.append(task.taskID)
        }
        if entry.type == "queue-operation", let content = entry.systemContent {
            ids.append(contentsOf: terminalNotificationTaskIDs(
                in: content,
                stoppingAtFirstEvent: stoppingAtFirstEvent
            ))
        }
        return ids
    }

    /// A Monitor event notification carries no `<status>`, so a persistent
    /// monitor's events clear nothing and only its closing notice does. A
    /// monitor that was not asked to persist stops at that first event
    /// instead, and some never write a closing notice at all — so for those
    /// the event is the end.
    private static func terminalNotificationTaskIDs(
        in content: String,
        stoppingAtFirstEvent: Set<String>
    ) -> [String] {
        guard let start = content.range(of: "<task-notification>") else { return [] }
        let rest = content[start.upperBound...]
        let header = rest.range(of: "<result>").map { rest[..<$0.lowerBound] } ?? rest
        let ids = tagValues("task-id", in: header)
        if let status = tagValue("status", in: header) {
            return isTerminal(status) ? ids : []
        }
        guard header.contains("<event>") else { return [] }
        return ids.filter { stoppingAtFirstEvent.contains($0) }
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
