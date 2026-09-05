import Foundation

nonisolated struct Transcript: Equatable {
    var messages: [ChatMessage] = []
    var latestUsage: TranscriptUsage?
    var model: String?
    var effort: String?
    var gitBranch: String?
    var cwd: String?
    var sessionID: String?
    /// The most recently referenced plan file, from a `plan_mode` or
    /// `plan_mode_exit` attachment line. Latest wins: a session typically
    /// iterates on one plan, and the newest reference is what's current.
    /// Whether the file still exists is a filesystem question, not something
    /// this records — a path here does not imply the file is on disk.
    var planFilePath: String?
    /// The session's current permission mode, from the latest
    /// `permission-mode` line.
    var permissionMode: String?
    /// The `stop_reason` of the most recent assistant turn to carry one.
    /// `end_turn` means the model finished speaking; `tool_use` means it
    /// stopped to call a tool and the turn continues.
    var lastStopReason: String?
}

/// Parses a Claude Code transcript JSONL into a `Transcript` of render-ready
/// `ChatMessage`s. Pure — no file I/O, no SwiftData.
nonisolated enum TranscriptParser {
    /// Where a pending tool call's block currently lives, so a later
    /// `tool_result` line can patch it in place.
    private enum ToolCallLocation {
        case pendingAssistant(blockIndex: Int)
        case flushedMessage(messageIndex: Int, blockIndex: Int)
    }

    /// A subagent's own transcript file marks every line `isSidechain`, so
    /// parsing one needs `includeSidechain` or it yields nothing at all.
    static func parse(_ data: Data, includeSidechain: Bool = false) -> Transcript {
        let decoder = JSONDecoder()
        var transcript = Transcript()

        // A pending, still-open run of assistant lines, folded into one
        // message once a non-assistant line breaks the run.
        var pendingAssistantBlocks: [ChatBlock] = []
        var pendingAssistantID: String?
        var pendingAssistantTimestamp: Date?

        var pendingToolCalls: [String: ToolCallLocation] = [:]

        func flushPendingAssistant() {
            guard !pendingAssistantBlocks.isEmpty else { return }
            let messageIndex = transcript.messages.count
            transcript.messages.append(ChatMessage(
                id: pendingAssistantID ?? UUID().uuidString,
                role: .assistant,
                blocks: pendingAssistantBlocks,
                timestamp: pendingAssistantTimestamp
            ))
            for (id, location) in pendingToolCalls {
                if case .pendingAssistant(let blockIndex) = location {
                    pendingToolCalls[id] = .flushedMessage(messageIndex: messageIndex, blockIndex: blockIndex)
                }
            }
            pendingAssistantBlocks = []
            pendingAssistantID = nil
            pendingAssistantTimestamp = nil
        }

        func applyResult(toolUseId: String, content: String?, images: [ChatImage]) {
            guard let location = pendingToolCalls.removeValue(forKey: toolUseId) else { return }
            switch location {
            case .pendingAssistant(let blockIndex):
                guard pendingAssistantBlocks.indices.contains(blockIndex),
                      case .toolCall(var call) = pendingAssistantBlocks[blockIndex]
                else { return }
                call.result = content
                call.resultImages = images
                pendingAssistantBlocks[blockIndex] = .toolCall(call)
            case .flushedMessage(let messageIndex, let blockIndex):
                guard transcript.messages.indices.contains(messageIndex),
                      transcript.messages[messageIndex].blocks.indices.contains(blockIndex),
                      case .toolCall(var call) = transcript.messages[messageIndex].blocks[blockIndex]
                else { return }
                call.result = content
                call.resultImages = images
                transcript.messages[messageIndex].blocks[blockIndex] = .toolCall(call)
            }
        }

        func appendNotice(_ notice: ChatNotice, id: String?, timestamp: Date?) {
            flushPendingAssistant()
            transcript.messages.append(ChatMessage(
                id: id ?? UUID().uuidString,
                role: .notice,
                blocks: [.notice(notice)],
                timestamp: timestamp
            ))
        }

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty, let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line)) else {
                continue
            }
            if entry.isSidechain, !includeSidechain { continue }

            if let usage = entry.message?.usage { transcript.latestUsage = usage }
            if let stopReason = entry.message?.stopReason { transcript.lastStopReason = stopReason }
            if let model = entry.message?.model { transcript.model = model }
            if let effort = entry.effort { transcript.effort = effort }
            if let gitBranch = entry.gitBranch { transcript.gitBranch = gitBranch }
            if let cwd = entry.cwd { transcript.cwd = cwd }
            if let sessionID = entry.sessionId { transcript.sessionID = sessionID }
            if let planFilePath = entry.attachment?.planFilePath { transcript.planFilePath = planFilePath }
            if let permissionMode = entry.permissionMode { transcript.permissionMode = permissionMode }

            if let notice = ChatNotice.decoding(entry) {
                appendNotice(notice, id: entry.uuid, timestamp: entry.timestamp)
                continue
            }

            guard let message = entry.message, let role = message.role else { continue }
            let contentBlocks = message.content?.blocks ?? []

            if entry.type == "assistant", entry.isApiErrorMessage {
                let text = contentBlocks.compactMap { block -> String? in
                    if case .text(let value) = block { return value }
                    return nil
                }.joined(separator: "\n")
                appendNotice(
                    ChatNotice(kind: .error, title: text.isEmpty ? "API error" : text, detail: nil),
                    id: entry.uuid,
                    timestamp: entry.timestamp
                )
                continue
            }

            switch (entry.type, role) {
            case ("assistant", "assistant"):
                for block in contentBlocks {
                    switch block {
                    case .text(let text):
                        pendingAssistantBlocks.append(.markdown(text))
                    case .thinking(let text):
                        pendingAssistantBlocks.append(.thinking(text))
                    case .toolUse(let id, let name, let input):
                        let call = ToolCall(
                            id: id,
                            name: name,
                            summary: ToolCallSummary.summary(name: name, input: input),
                            input: ToolCallInputRendering.render(
                                name: name,
                                input: input,
                                prettyJSON: prettyPrint(input)
                            ),
                            interactive: InteractiveToolPayload.decoding(name: name, input: input),
                            result: nil
                        )
                        pendingAssistantBlocks.append(.toolCall(call))
                        pendingToolCalls[id] = .pendingAssistant(blockIndex: pendingAssistantBlocks.count - 1)
                    case .image(let image):
                        pendingAssistantBlocks.append(.image(image))
                    case .toolResult, .ignored:
                        continue
                    }
                }
                if pendingAssistantID == nil { pendingAssistantID = entry.uuid }
                if pendingAssistantTimestamp == nil { pendingAssistantTimestamp = entry.timestamp }

            case ("user", "user"):
                flushPendingAssistant()

                var results: [(toolUseId: String, content: String?, images: [ChatImage])] = []
                var texts: [String] = []
                var otherBlocks: [ChatBlock] = []
                for block in contentBlocks {
                    switch block {
                    case .toolResult(let toolUseId, let content, let images):
                        results.append((toolUseId, content, images))
                    case .text(let text):
                        texts.append(text)
                    case .thinking(let text):
                        otherBlocks.append(.thinking(text))
                    case .image(let image):
                        otherBlocks.append(.image(image))
                    case .toolUse, .ignored:
                        continue
                    }
                }

                for result in results {
                    applyResult(toolUseId: result.toolUseId, content: result.content, images: result.images)
                }

                // One line's text blocks are one unit of injected content, so
                // they classify together rather than block by block.
                let text = texts.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let kind = InjectedContent.classify(
                        text: text,
                        isMeta: entry.isMeta,
                        isCompactSummary: entry.isCompactSummary
                    )
                    otherBlocks.insert(
                        kind.isUserProse ? .markdown(text) : .injected(kind, text: text),
                        at: 0
                    )
                }

                // A user message made up only of tool_results carries no
                // message of its own — the results attach to the tool calls.
                guard !otherBlocks.isEmpty else { continue }
                transcript.messages.append(ChatMessage(
                    id: entry.uuid ?? UUID().uuidString,
                    role: .user,
                    blocks: otherBlocks,
                    timestamp: entry.timestamp
                ))

            default:
                continue
            }
        }

        flushPendingAssistant()
        return transcript
    }

    private static func prettyPrint(_ input: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder.sortedKeys.encode(input.mapValues(EncodableJSONValue.init)),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct EncodableJSONValue: Encodable {
    let value: JSONValue

    nonisolated init(_ value: JSONValue) {
        self.value = value
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .bool(let bool): try container.encode(bool)
        case .null: try container.encodeNil()
        case .array(let array): try container.encode(array.map(EncodableJSONValue.init))
        case .object(let object): try container.encode(object.mapValues(EncodableJSONValue.init))
        }
    }
}
