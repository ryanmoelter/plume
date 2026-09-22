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
    /// When the first line of the file was written, and when the last was.
    /// Both come from the lines' own `timestamp`, so they survive a relaunch
    /// and describe the conversation rather than the file — a copied or
    /// re-read transcript reports the same span.
    var startedAt: Date?
    var lastActivityAt: Date?
    /// The `stop_reason` of the most recent assistant turn to carry one, or
    /// nil once a new prompt opens another turn. `end_turn` means the model
    /// finished speaking; `tool_use` means it stopped to call a tool and the
    /// turn continues.
    var lastStopReason: String?
    /// Whether the current turn's latest tool call is an accepted
    /// `SubagentHandback`, which is how a subagent delivers its final report.
    /// A nested subagent's completion is recorded only in its parent
    /// subagent's file, so this is the one signal its own transcript carries.
    var handedBack = false
    /// The uuids of transcript rows with more than one real child — a
    /// deliberate edit or retry rather than the single, linear continuation
    /// most rows have. Keyed by the parent row's own uuid.
    var forkPoints: Set<String> = []
    /// Every rendered message on every branch a fork point left behind, in
    /// file order, keyed by the fork's parent uuid. The branch that reaches
    /// the file's last row is the live one and is not included here — it
    /// stays in `messages` as normal.
    var abandonedBranches: [String: [ChatMessage]] = [:]
    /// Each row's `parentUuid`, for every row the file names — including the
    /// ones no rendered message came from. A fork cuts at the target's parent
    /// rather than the target, so the redo action reads it from here.
    var parentByMessageID: [String: String] = [:]

    /// Whether `messageID` is a row where the conversation forked.
    func isForkPoint(messageID: String) -> Bool {
        forkPoints.contains(messageID)
    }
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

    /// One line's contribution to the branch tree: the entries needed to
    /// tell a genuine fork (a deliberate edit or retry) from the ordinary
    /// case of a row having exactly one child.
    private struct BranchChild {
        let uuid: String
        let type: String
        let isApiErrorMessage: Bool
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
        var assistantIDs: Set<String> = []

        // The tree: every row keyed by uuid, deduped (first occurrence
        // wins), plus which rows became which rendered message. Built
        // alongside the render pass rather than in a second pass over the
        // file — resolving forks afterward only walks this in-memory data.
        var seenUUIDs = Set<String>()
        var childrenByParent: [String: [BranchChild]] = [:]
        // Every child, attachments included. Fork detection has to skip
        // attachments, but collecting a branch cannot: attachments chain, so
        // a branch that runs through one loses every row below it otherwise.
        var allChildrenByParent: [String: [String]] = [:]
        var messageIndexByUUID: [String: Int] = [:]
        var parentByUUID: [String: String] = [:]
        // The file's last row with a uuid, whatever its type — Claude Code
        // only ever appends to the branch it is currently on, so this row is
        // the tip of the surviving path.
        var tipUUID: String?

        func flushPendingAssistant() {
            guard !pendingAssistantBlocks.isEmpty else { return }
            let messageIndex = transcript.messages.count
            transcript.messages.append(ChatMessage(
                id: pendingAssistantID ?? UUID().uuidString,
                role: .assistant,
                blocks: pendingAssistantBlocks,
                timestamp: pendingAssistantTimestamp
            ))
            if let id = pendingAssistantID { messageIndexByUUID[id] = messageIndex }
            for (id, location) in pendingToolCalls {
                if case .pendingAssistant(let blockIndex) = location {
                    pendingToolCalls[id] = .flushedMessage(messageIndex: messageIndex, blockIndex: blockIndex)
                }
            }
            pendingAssistantBlocks = []
            pendingAssistantID = nil
            pendingAssistantTimestamp = nil
        }

        func applyResult(toolUseId: String, content: String?, images: [ChatImage], isError: Bool) {
            guard let location = pendingToolCalls.removeValue(forKey: toolUseId) else { return }
            switch location {
            case .pendingAssistant(let blockIndex):
                guard pendingAssistantBlocks.indices.contains(blockIndex),
                      case .toolCall(var call) = pendingAssistantBlocks[blockIndex]
                else { return }
                call.result = content
                call.resultImages = images
                call.didFail = isError
                pendingAssistantBlocks[blockIndex] = .toolCall(call)
            case .flushedMessage(let messageIndex, let blockIndex):
                guard transcript.messages.indices.contains(messageIndex),
                      transcript.messages[messageIndex].blocks.indices.contains(blockIndex),
                      case .toolCall(var call) = transcript.messages[messageIndex].blocks[blockIndex]
                else { return }
                call.result = content
                call.resultImages = images
                call.didFail = isError
                transcript.messages[messageIndex].blocks[blockIndex] = .toolCall(call)
            }
        }

        func appendNotice(_ notice: ChatNotice, id: String?, timestamp: Date?) {
            flushPendingAssistant()
            let messageIndex = transcript.messages.count
            transcript.messages.append(ChatMessage(
                id: id ?? UUID().uuidString,
                role: .notice,
                blocks: [.notice(notice)],
                timestamp: timestamp
            ))
            if let id { messageIndexByUUID[id] = messageIndex }
        }

        // A `<local-command-stdout>` line names no command, so the row takes
        // its title from the `<command-name>` line that preceded it.
        var lastSlashCommand: String?
        var handbackID: String?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty, let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line)) else {
                continue
            }
            if entry.isSidechain, !includeSidechain { continue }

            // One real transcript carries 1,339 byte-identical duplicate
            // lines; without this a duplicated parent reads as forking.
            if let uuid = entry.uuid {
                guard seenUUIDs.insert(uuid).inserted else { continue }
                tipUUID = uuid
                if let parentUuid = entry.parentUuid { parentByUUID[uuid] = parentUuid }
            }
            if let parentUuid = entry.parentUuid, let uuid = entry.uuid {
                allChildrenByParent[parentUuid, default: []].append(uuid)
                if entry.type != "attachment" {
                    childrenByParent[parentUuid, default: []].append(
                        BranchChild(uuid: uuid, type: entry.type, isApiErrorMessage: entry.isApiErrorMessage)
                    )
                }
            }

            if let timestamp = entry.timestamp {
                if transcript.startedAt == nil { transcript.startedAt = timestamp }
                transcript.lastActivityAt = timestamp
            }
            if let usage = entry.message?.usage { transcript.latestUsage = usage }
            if let stopReason = entry.message?.stopReason { transcript.lastStopReason = stopReason }
            // A resumed subagent's previous `end_turn` would otherwise read as
            // done until its new run's first response closes.
            if entry.isPrompt {
                transcript.lastStopReason = nil
                handbackID = nil
            }
            // Only the turn's latest tool call counts: an agent can keep working
            // after handing back, and a rejected hand-back delivered nothing.
            for block in entry.message?.content?.blocks ?? [] {
                switch block {
                case .toolUse(let id, let name, _) where entry.type == "assistant":
                    handbackID = name == "SubagentHandback" ? id : nil
                case .toolResult(let toolUseId, _, _, true) where toolUseId == handbackID:
                    handbackID = nil
                default:
                    break
                }
            }
            transcript.handedBack = handbackID != nil
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
                        // A redacted block, signature only. The stream merges
                        // no block for it, and an extra one here would shift
                        // the positions that piece ids are built from.
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        pendingAssistantBlocks.append(.thinking(text))
                    case .toolUse(let id, let name, let input):
                        let call = ToolCall(
                            id: id,
                            name: name,
                            summary: ToolCallSummary(name: name, input: input),
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
                    case .toolResult, .toolReference, .ignored:
                        continue
                    }
                }
                // Keyed by the API message id, which the live stream also
                // knows, so the reply keeps its identity when the transcript
                // takes it over. The line's own uuid covers a repeat.
                if pendingAssistantID == nil {
                    if let apiID = message.id, assistantIDs.insert(apiID).inserted {
                        pendingAssistantID = apiID
                    } else {
                        pendingAssistantID = entry.uuid
                    }
                }
                if pendingAssistantTimestamp == nil { pendingAssistantTimestamp = entry.timestamp }

            case ("user", "user"):
                flushPendingAssistant()

                var results: [(toolUseId: String, content: String?, images: [ChatImage], isError: Bool)] = []
                var texts: [String] = []
                var otherBlocks: [ChatBlock] = []
                for block in contentBlocks {
                    switch block {
                    case .toolResult(let toolUseId, let content, let images, let isError):
                        results.append((toolUseId, content, images, isError))
                    case .text(let text):
                        texts.append(text)
                    case .thinking(let text):
                        otherBlocks.append(.thinking(text))
                    case .image(let image):
                        otherBlocks.append(.image(image))
                    case .toolUse, .toolReference, .ignored:
                        continue
                    }
                }

                for result in results {
                    applyResult(
                        toolUseId: result.toolUseId,
                        content: result.content,
                        images: result.images,
                        isError: result.isError
                    )
                }

                // One line's text blocks are one unit of injected content, so
                // they classify together rather than block by block.
                let text = texts.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let kind = InjectedContent.classify(
                        text: text,
                        isMeta: entry.isMeta,
                        isCompactSummary: entry.isCompactSummary,
                        precedingCommand: lastSlashCommand
                    )
                    switch kind {
                    case .slashCommand: lastSlashCommand = kind.markerLabel
                    // The caveat sits between a command and its output.
                    case .commandCaveat: break
                    default: lastSlashCommand = nil
                    }
                    otherBlocks.insert(
                        kind.isUserProse ? .markdown(kind.bodyText(text)) : .injected(kind, text: text),
                        at: 0
                    )
                }

                // A user message made up only of tool_results carries no
                // message of its own — the results attach to the tool calls.
                guard !otherBlocks.isEmpty else { continue }
                let messageIndex = transcript.messages.count
                transcript.messages.append(ChatMessage(
                    id: entry.uuid ?? UUID().uuidString,
                    role: .user,
                    blocks: otherBlocks,
                    timestamp: entry.timestamp
                ))
                if let uuid = entry.uuid { messageIndexByUUID[uuid] = messageIndex }

            default:
                continue
            }
        }

        flushPendingAssistant()
        transcript.parentByMessageID = parentByUUID
        resolveForks(
            in: &transcript,
            childrenByParent: childrenByParent,
            allChildrenByParent: allChildrenByParent,
            messageIndexByUUID: messageIndexByUUID,
            parentByUUID: parentByUUID,
            tipUUID: tipUUID
        )
        return transcript
    }

    /// The uuids on the path from the root down to `tip` — the branch
    /// Claude Code kept appending to, since it only ever continues from
    /// wherever the file last left off. Iterative: a transcript can be many
    /// thousands of rows deep, deep enough to blow the stack if this walked
    /// `parentUuid` by recursion.
    private static func liveUUIDs(upTo tip: String?, parentByUUID: [String: String]) -> Set<String> {
        var live = Set<String>()
        var current = tip
        while let uuid = current, live.insert(uuid).inserted {
            current = parentByUUID[uuid]
        }
        return live
    }

    /// A parent with >=2 real children (attachments never count, and a
    /// matched `api_error` retry pair doesn't either) forked. Exactly one
    /// child sits on the live path traced from the file's last row back to
    /// the root; every other child, and everything descending from it, is
    /// an abandoned branch.
    private static func resolveForks(
        in transcript: inout Transcript,
        childrenByParent: [String: [BranchChild]],
        allChildrenByParent: [String: [String]],
        messageIndexByUUID: [String: Int],
        parentByUUID: [String: String],
        tipUUID: String?
    ) {
        let live = liveUUIDs(upTo: tipUUID, parentByUUID: parentByUUID)

        for (parentUuid, children) in childrenByParent {
            guard children.count >= 2, !isApiErrorRetryPair(children) else { continue }
            transcript.forkPoints.insert(parentUuid)

            let abandonedRoots = children.filter { !live.contains($0.uuid) }
            let indices = abandonedRoots.flatMap {
                subtreeMessageIndices(
                    rootUUID: $0.uuid,
                    allChildrenByParent: allChildrenByParent,
                    messageIndexByUUID: messageIndexByUUID
                )
            }.sorted()
            let abandoned = indices.map { transcript.messages[$0] }
            if !abandoned.isEmpty {
                transcript.abandonedBranches[parentUuid] = abandoned
            }
        }
    }

    /// The rendered-message indices descending from `rootUUID`, sorted back
    /// into file order. Iterative for the same reason `liveUUIDs` is — an
    /// abandoned branch can itself be many rows deep.
    private static func subtreeMessageIndices(
        rootUUID: String,
        allChildrenByParent: [String: [String]],
        messageIndexByUUID: [String: Int]
    ) -> [Int] {
        var indices: [Int] = []
        var stack = [rootUUID]
        var visited = Set<String>()
        while let uuid = stack.popLast() {
            guard visited.insert(uuid).inserted else { continue }
            if let index = messageIndexByUUID[uuid] { indices.append(index) }
            stack.append(contentsOf: allChildrenByParent[uuid] ?? [])
        }
        return indices
    }

    /// The mechanical retry Claude Code performs on an API error: the
    /// assistant line it flags itself, paired with the `system`/`api_error`
    /// line reporting it. Not a user-facing branch.
    private static func isApiErrorRetryPair(_ children: [BranchChild]) -> Bool {
        guard children.count == 2 else { return false }
        let types = Set(children.map(\.type))
        guard types == ["assistant", "system"] else { return false }
        return children.contains { $0.type == "assistant" && $0.isApiErrorMessage }
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
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
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
