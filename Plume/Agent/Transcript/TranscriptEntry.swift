import Foundation

/// A JSON value of unknown shape, for fields like `tool_use.input` whose
/// keys are tool-specific. Decodes any JSON; encodes back losslessly.
nonisolated enum JSONValue: Decodable, Encodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Reads a field of an object, so a decoder can walk a payload without
    /// unwrapping at every level.
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    /// Convenience accessor for table-driven tool summaries.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

/// One line of a Claude Code transcript JSONL.
///
/// Forgiving like `HookEvent`: unknown `type`s and unknown content block
/// types decode to an ignored case rather than throwing, since a transcript
/// is mostly line shapes Plume does not model.
nonisolated struct TranscriptEntry: Decodable {
    let type: String
    let uuid: String?
    let parentUuid: String?
    let timestamp: Date?
    let isSidechain: Bool
    let agentId: String?
    let cwd: String?
    let gitBranch: String?
    let effort: String?
    let sessionId: String?
    /// Set only on `permission-mode` lines, which Claude Code writes on every
    /// change of mode.
    let permissionMode: String?
    /// Marks a user line Claude Code synthesized rather than one the user
    /// typed. True for a skill body and a caveat block, but false for a slash
    /// command's expansion and its output — see `InjectedContent`.
    let isMeta: Bool
    /// Marks the summary a compaction writes back into the conversation. It
    /// arrives as a `user` line so the model reads it as context, but the
    /// user did not write it and it runs to thousands of words — the chat
    /// collapses it rather than attributing it to them.
    let isCompactSummary: Bool
    let message: TranscriptMessage?
    let attachment: TranscriptAttachment?
    /// A tool call's structured outcome, which is where a spawning `Task` call
    /// records the subagent it launched and whether that agent finished.
    let toolUseResult: TranscriptToolUseResult?
    /// Set on `queue-operation` lines: `enqueue` or `dequeue`.
    let operation: String?
    /// The task notification a `queue-operation` line carries, which is how
    /// the CLI reports that a subagent stopped.
    let taskNotification: TranscriptTaskNotification?
    /// Set on `system` lines: `compact_boundary`, `api_error`,
    /// `turn_duration`, and a long tail of bookkeeping kinds.
    let subtype: String?
    /// A `system` line's severity — `error`, `warning`, `info`, `notice`.
    let level: String?
    /// A `system` line's own `content`, which is a plain string rather than
    /// the block array a message's content is.
    let systemContent: String?
    let compactMetadata: CompactMetadata?
    /// A human-readable summary of an `api_error` line's nested error object.
    let errorDescription: String?
    /// Claude Code's own flag that an assistant line is an error report
    /// rather than the model speaking.
    let isApiErrorMessage: Bool

    enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, timestamp, isSidechain, agentId, cwd, gitBranch, effort, sessionId, message
        case permissionMode
        case isMeta
        case isCompactSummary
        case attachment
        case toolUseResult
        case subtype, level, content, compactMetadata, error
        case operation
        case isApiErrorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        parentUuid = try container.decodeIfPresent(String.self, forKey: .parentUuid)
        isSidechain = try container.decodeIfPresent(Bool.self, forKey: .isSidechain) ?? false
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        isMeta = try container.decodeIfPresent(Bool.self, forKey: .isMeta) ?? false
        isCompactSummary = try container.decodeIfPresent(Bool.self, forKey: .isCompactSummary) ?? false
        message = try container.decodeIfPresent(TranscriptMessage.self, forKey: .message)
        attachment = try container.decodeIfPresent(TranscriptAttachment.self, forKey: .attachment)
        // Sometimes a bare string rather than an object, so a failure here is
        // ordinary rather than a malformed line.
        toolUseResult = try? container.decodeIfPresent(TranscriptToolUseResult.self, forKey: .toolUseResult)
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        systemContent = try? container.decodeIfPresent(String.self, forKey: .content)
        compactMetadata = try? container.decodeIfPresent(CompactMetadata.self, forKey: .compactMetadata)
        errorDescription = TranscriptEntry.describeError(
            try? container.decodeIfPresent(JSONValue.self, forKey: .error)
        )
        isApiErrorMessage = try container.decodeIfPresent(Bool.self, forKey: .isApiErrorMessage) ?? false
        taskNotification = type == "queue-operation"
            ? systemContent.flatMap(TranscriptTaskNotification.init(content:))
            : nil

        if let raw = try container.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = TranscriptEntry.isoFormatter.date(from: raw)
        } else {
            timestamp = nil
        }
    }

    /// An `api_error`'s payload nests the real message a couple of levels
    /// down (`error.error.error.message`), with an HTTP `status` beside it.
    private static func describeError(_ value: JSONValue?) -> String? {
        guard let value, case .object(let object) = value else { return nil }
        var parts: [String] = []
        if let status = object["status"]?.doubleValue { parts.append("HTTP \(Int(status))") }
        if let message = deepMessage(object) { parts.append(message) }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    private static func deepMessage(_ object: [String: JSONValue]) -> String? {
        if let message = object["message"]?.stringValue { return message }
        if let nested = object["error"]?.objectValue { return deepMessage(nested) }
        return object["type"]?.stringValue
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

nonisolated struct TranscriptMessage: Decodable {
    let role: String?
    let model: String?
    let usage: TranscriptUsage?
    let content: TranscriptContent?
    /// Why the model stopped this turn — `end_turn` when it finished
    /// speaking, `tool_use` when it stopped to call a tool. Only the line
    /// closing an API response carries it, so most lines leave it nil.
    let stopReason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        usage = try container.decodeIfPresent(TranscriptUsage.self, forKey: .usage)
        content = try container.decodeIfPresent(TranscriptContent.self, forKey: .content)
        stopReason = try? container.decodeIfPresent(String.self, forKey: .stopReason)
    }

    enum CodingKeys: String, CodingKey {
        case role, model, usage, content
        case stopReason = "stop_reason"
    }
}

nonisolated struct TranscriptUsage: Decodable, Equatable {
    let inputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
    }

    var contextUsedTokens: Int? {
        ContextUsage.total(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            output: outputTokens
        )
    }
}

/// A message's `content` is either a bare string (plain user messages) or an
/// array of typed blocks (assistant messages, and user messages carrying
/// tool results).
nonisolated struct TranscriptContent: Decodable {
    let blocks: [TranscriptBlock]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            blocks = [.text(text)]
        } else if let array = try? container.decode([TranscriptBlock].self) {
            blocks = array
        } else {
            blocks = []
        }
    }
}

/// A tool call's structured outcome. Only the fields that identify a spawned
/// subagent and its fate are modeled; the rest of the payload is the report
/// text and token accounting, which the chat renders from the message blocks.
nonisolated struct TranscriptToolUseResult: Decodable {
    let agentID: String?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case agentId, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try? container.decodeIfPresent(String.self, forKey: .agentId)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
    }
}

/// How a background agent's completion reaches the parent when the parent
/// never blocked on the spawning call. `taskId` is the agent's own id.
nonisolated struct TranscriptTaskStatus: Decodable {
    let taskID: String
    let status: String?
}

/// A `<task-notification>` block, which the CLI enqueues each time a subagent
/// stops. It names the agent by `task-id` and its outcome by `status`.
///
/// The payload is a plain string rather than JSON fields, so this degrades to
/// no signal rather than to a wrong one: anything it does not recognize yields
/// nil. Tags are read only from the header, before the `<result>` body, since
/// an agent's own report can quote the same tags.
nonisolated struct TranscriptTaskNotification: Equatable {
    let taskID: String
    /// `completed`, `failed`, `killed` or `stopped` in the corpus. Left as
    /// written so the reader decides what an unfamiliar word means.
    let status: String?

    init?(content: String) {
        guard let header = Self.header(of: content),
              let taskID = Self.tagValue("task-id", in: header)
        else { return nil }
        self.taskID = taskID
        status = Self.tagValue("status", in: header)
    }

    private static func header(of content: String) -> Substring? {
        guard let start = content.range(of: "<task-notification>") else { return nil }
        let rest = content[start.upperBound...]
        guard let body = rest.range(of: "<result>") else { return rest }
        return rest[..<body.lowerBound]
    }

    private static func tagValue(_ tag: String, in header: Substring) -> String? {
        guard let open = header.range(of: "<\(tag)>"),
              let close = header.range(of: "</\(tag)>", range: open.upperBound..<header.endIndex)
        else { return nil }
        let value = header[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// A top-level `attachment` line's payload. Only `plan_mode`,
/// `plan_mode_exit` and `task_status` are modeled — the first two carry a
/// `planFilePath` recording where Claude Code intended to write the plan,
/// whether or not it exists on disk at the time the line was written.
nonisolated struct TranscriptAttachment: Decodable {
    let planFilePath: String?
    let taskStatus: TranscriptTaskStatus?

    private enum CodingKeys: String, CodingKey {
        case type, planFilePath, taskId, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "plan_mode", "plan_mode_exit":
            planFilePath = try container.decodeIfPresent(String.self, forKey: .planFilePath)
            taskStatus = nil
        case "task_status":
            planFilePath = nil
            taskStatus = try container.decodeIfPresent(String.self, forKey: .taskId).map {
                TranscriptTaskStatus(
                    taskID: $0,
                    status: try? container.decodeIfPresent(String.self, forKey: .status)
                )
            }
        default:
            planFilePath = nil
            taskStatus = nil
        }
    }
}

nonisolated enum TranscriptBlock: Decodable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseId: String, content: String?, images: [ChatImage], isError: Bool)
    case image(ChatImage)
    case ignored

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
        case source
    }

    private enum SourceKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try container.decodeIfPresent(String.self, forKey: .thinking) ?? "")
        case "tool_use":
            let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            let input = try container.decodeIfPresent([String: JSONValue].self, forKey: .input) ?? [:]
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId) ?? ""
            let (text, images) = try TranscriptBlock.decodeResultContent(container)
            let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self = .toolResult(toolUseId: toolUseId, content: text, images: images, isError: isError)
        case "image":
            guard let image = try TranscriptBlock.decodeImage(container) else {
                self = .ignored
                return
            }
            self = .image(image)
        default:
            self = .ignored
        }
    }

    /// Only base64 sources are modeled. A URL source would need a fetch,
    /// which the parser must stay free of.
    private static func decodeImage(_ container: KeyedDecodingContainer<CodingKeys>) throws -> ChatImage? {
        guard let source = try? container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source),
              (try? source.decodeIfPresent(String.self, forKey: .type)) == "base64",
              let data = try? source.decodeIfPresent(String.self, forKey: .data), !data.isEmpty
        else { return nil }
        let mediaType = try? source.decodeIfPresent(String.self, forKey: .mediaType)
        return ChatImage(mediaType: mediaType ?? "image/png", base64: data)
    }

    /// `tool_result.content` is a plain string, an array of blocks, or
    /// absent entirely. Text blocks join into the result body; image blocks
    /// come back alongside it — a screenshot tool returns exactly that.
    private static func decodeResultContent(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> (String?, [ChatImage]) {
        if let string = try? container.decodeIfPresent(String.self, forKey: .content) {
            return (string, [])
        }
        guard let blocks = try? container.decodeIfPresent([TranscriptBlock].self, forKey: .content) else {
            return (nil, [])
        }
        let text = blocks.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: "\n")
        let images = blocks.compactMap { block -> ChatImage? in
            if case .image(let image) = block { return image }
            return nil
        }
        return (text.isEmpty ? nil : text, images)
    }
}
