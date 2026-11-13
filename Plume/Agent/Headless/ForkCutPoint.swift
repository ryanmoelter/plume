import Foundation

/// The latest main-thread row a fork can cut at with `--resume-session-at`:
/// the newest user row, a prompt or a tool result, after which no tool call
/// is still open.
///
/// A cut inside a tool call is accepted, but the fork then opens on a
/// synthetic "Tool result missing" for the cut-off call. A row on another
/// branch, or one the file never got, makes the CLI exit with `No message
/// found with message.uuid`. "Forking" in docs/headless-protocol.md has the
/// probe.
nonisolated struct ForkCutPoint: Equatable {
    private(set) var uuid: String?
    private var openToolUseIDs: Set<String> = []
    private var promptUUID: String?

    /// A prompt that starts a new turn, so no tool call is open.
    mutating func promptSent(_ uuid: String) {
        openToolUseIDs.removeAll()
        promptUUID = uuid
        self.uuid = uuid
    }

    /// Feed only main-thread envelopes; a subagent's rows are on its own chain.
    mutating func assistant(_ envelope: MessageEnvelope) {
        if let prompt = envelope.userMessageUUID, prompt != promptUUID {
            promptUUID = prompt
            if openToolUseIDs.isEmpty { uuid = prompt }
        }
        for block in Self.content(of: envelope) where block["type"]?.stringValue == "tool_use" {
            if let id = block["id"]?.stringValue { openToolUseIDs.insert(id) }
        }
    }

    mutating func user(_ envelope: MessageEnvelope) {
        let results = Self.content(of: envelope).filter { $0["type"]?.stringValue == "tool_result" }
        guard !results.isEmpty else { return }
        for result in results {
            if let id = result["tool_use_id"]?.stringValue { openToolUseIDs.remove(id) }
        }
        if openToolUseIDs.isEmpty, let row = envelope.uuid { uuid = row }
    }

    /// A call an interrupt cut off never gets a result on the stream.
    mutating func turnEnded() {
        openToolUseIDs.removeAll()
    }

    private static func content(of envelope: MessageEnvelope) -> [[String: JSONValue]] {
        (envelope.raw["content"]?.arrayValue ?? []).compactMap(\.objectValue)
    }
}
