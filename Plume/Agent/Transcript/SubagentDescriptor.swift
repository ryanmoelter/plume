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

    var isEmpty: Bool {
        description == nil && agentType == nil && toolUseID == nil
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
            toolUseID: sidecar.toolUseId?.nonEmpty
        )
        return descriptor.isEmpty ? nil : descriptor
    }

    private struct Sidecar: Decodable {
        let description: String?
        let agentType: String?
        let toolUseId: String?
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
                case .toolResult(let toolUseId, let content, _):
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
/// Both records that carry it name the agent directly, so nothing here has to
/// go through the spawning tool call: a `toolUseResult` reports `agentId` with
/// its status, and a `task_status` attachment reports `taskId`.
nonisolated struct SubagentSpawnResults {
    private let signalsByAgentID: [String: SubagentParentSignal]

    init(parentData: Data) {
        var signals: [String: SubagentParentSignal] = [:]
        let decoder = JSONDecoder()

        // A completed report can only follow the launch that produced it, so
        // it must never be overwritten by an earlier record for the same agent.
        func record(_ signal: SubagentParentSignal, for agentID: String) {
            guard signals[agentID] != .completed else { return }
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
        }

        signalsByAgentID = signals
    }

    func signal(forAgentID agentID: String) -> SubagentParentSignal? {
        signalsByAgentID[agentID]
    }

    /// Anything that is not a launch acknowledgement and not an outright
    /// failure is a real report, so an unfamiliar status reads as done rather
    /// than pinning the row at working forever.
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
