import Foundation

/// What a subagent was asked to do, and which parent tool call spawned it.
///
/// Claude Code writes an `agent-<id>.meta.json` sidecar beside each subagent
/// transcript carrying exactly this, so the sidecar is the primary source and
/// scanning the parent for the spawning `Task`/`Agent` call is the fallback
/// for transcripts written before it existed.
nonisolated struct SubagentDescriptor: Equatable {
    var description: String?
    var agentType: String?
    var toolUseID: String?
    /// The model the sidecar records, which names one before the agent's own
    /// transcript has an assistant line to read it from.
    var model: String?
    /// The user ended this agent. It still gets a `completed` task
    /// notification like any other, so this flag is the only thing that
    /// separates the two.
    var stoppedByUser: Bool = false

    var isEmpty: Bool {
        description == nil && agentType == nil && toolUseID == nil && model == nil && !stoppedByUser
    }

    /// `agentType: description`, matching how `ToolCallSummary` renders an
    /// `Agent` call, and falling back to whichever half exists.
    func label(fallback: String) -> String {
        switch (agentType, description) {
        case (let type?, let description?): "\(type): \(description)"
        case (nil, let description?): description
        case (let type?, nil): type
        default: fallback
        }
    }
}

nonisolated enum SubagentMetadataReader {
    /// The sidecar sits beside the transcript, named for it.
    static func metadataPath(forSubagentPath subagentPath: String) -> String {
        (subagentPath as NSString).deletingPathExtension + ".meta.json"
    }

    static func read(forSubagentPath subagentPath: String) -> SubagentDescriptor? {
        guard let data = FileManager.default.contents(atPath: metadataPath(forSubagentPath: subagentPath)) else {
            return nil
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> SubagentDescriptor? {
        guard let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return nil }
        let descriptor = SubagentDescriptor(
            description: sidecar.description?.nonEmpty,
            agentType: sidecar.agentType?.nonEmpty,
            toolUseID: sidecar.toolUseId?.nonEmpty,
            model: sidecar.model?.nonEmpty,
            stoppedByUser: sidecar.stoppedByUser ?? false
        )
        return descriptor.isEmpty ? nil : descriptor
    }

    private struct Sidecar: Decodable {
        let description: String?
        let agentType: String?
        let toolUseId: String?
        let model: String?
        let stoppedByUser: Bool?
    }
}

/// Recovers a subagent's description from the parent transcript's spawning
/// tool call, for sessions with no `.meta.json` sidecar.
nonisolated enum SubagentSpawnScanner {
    /// Both names have been used for the subagent-spawning tool.
    private static let spawnToolNames: Set<String> = ["Task", "Agent"]

    /// Every subagent spawn the parent transcript records, keyed by the
    /// spawned agent's id where the result names one.
    ///
    /// A spawn's tool_result carries the `agentId` of the subagent it
    /// launched, which is the only link between a `Task` call and the
    /// `agent-<id>.jsonl` it produced — the tool_use itself names no agent.
    static func descriptors(in data: Data) -> [String: SubagentDescriptor] {
        var byToolUseID: [String: SubagentDescriptor] = [:]
        var agentIDByToolUseID: [String: String] = [:]
        let decoder = JSONDecoder()

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line)),
                  let blocks = entry.message?.content?.blocks
            else { continue }

            for block in blocks {
                switch block {
                case .toolUse(let id, let name, let input):
                    guard spawnToolNames.contains(name) else { continue }
                    byToolUseID[id] = SubagentDescriptor(
                        description: input["description"]?.stringValue?.nonEmpty,
                        agentType: input["subagent_type"]?.stringValue?.nonEmpty,
                        toolUseID: id
                    )
                case .toolResult(let toolUseId, let content, _, _):
                    guard let content, let agentID = agentID(in: content) else { continue }
                    agentIDByToolUseID[toolUseId] = agentID
                default:
                    continue
                }
            }
        }

        return agentIDByToolUseID.reduce(into: [:]) { result, pair in
            result[pair.value] = byToolUseID[pair.key]
        }
    }

    /// The spawn result reports the id as `agentId: <id>` on its own line.
    private static func agentID(in content: String) -> String? {
        guard let range = content.range(of: "agentId:") else { return nil }
        let rest = content[range.upperBound...]
        let token = rest.drop { $0 == " " }.prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }
}

/// What the parent transcript says about each subagent's outcome, keyed by the
/// spawned agent's id.
///
/// Every record that carries it names the agent directly, so nothing here has
/// to go through the spawning tool call: a `toolUseResult` reports `agentId`
/// with its status, a `task_status` attachment reports `taskId`, and the
/// `<task-notification>` on a `queue-operation` line reports `task-id`.
///
/// The notification is the one current CLI builds actually write. `task_status`
/// appears nowhere in the sampled corpus, which is what left finished
/// subagents reading `working`.
nonisolated struct SubagentSpawnResults {
    private let signalsByAgentID: [String: SubagentParentSignal]

    init(parentData: Data) {
        var signals: [String: SubagentParentSignal] = [:]
        let decoder = JSONDecoder()

        // A completed report can only follow the launch that produced it, so
        // it must never be overwritten by an earlier record for the same agent.
        // A stop is kept for the same reason, against the launch that preceded
        // it, but still yields to a completion — an agent resumed after a stop
        // goes on to report.
        func record(_ signal: SubagentParentSignal, for agentID: String) {
            guard signals[agentID] != .completed else { return }
            guard !(signals[agentID] == .stopped && signal != .completed) else { return }
            signals[agentID] = signal
        }

        for line in parentData.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line))
            else { continue }

            if let outcome = entry.toolUseResult, let agentID = outcome.agentID {
                record(Self.signal(forStatus: outcome.status), for: agentID)
            }
            if let task = entry.attachment?.taskStatus {
                record(Self.signal(forStatus: task.status), for: task.taskID)
            }
            if let notification = entry.taskNotification,
               let signal = Self.signal(forNotificationStatus: notification.status) {
                record(signal, for: notification.taskID)
            }
        }

        signalsByAgentID = signals
    }

    func signal(forAgentID agentID: String) -> SubagentParentSignal? {
        signalsByAgentID[agentID]
    }

    /// Anything that is not a launch acknowledgement and not an outright
    /// failure is a real report, so an unfamiliar status reads as done rather
    /// than pinning the row at working forever.
    /// A notification's status is a word lifted out of a plain string, so an
    /// unrecognized one yields no signal at all rather than a wrong one.
    ///
    /// `killed` and `stopped` say the agent is no longer running without
    /// saying what it did. The CLI writes them only once it has stopped, so
    /// they cannot fold away live work — and they are the only record of an
    /// agent that died mid-tool-call, whose own transcript ends on an
    /// attachment with no interruption marker to read.
    private static func signal(forNotificationStatus status: String?) -> SubagentParentSignal? {
        switch status {
        case "completed": .completed
        case "failed", "error": .failed
        case "killed", "stopped": .stopped
        default: nil
        }
    }

    private static func signal(forStatus status: String?) -> SubagentParentSignal {
        switch status {
        case "async_launched", "forked": .launched
        case "failed", "error": .failed
        default: .completed
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
