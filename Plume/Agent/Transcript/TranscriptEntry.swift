import Foundation

/// A JSON value of unknown shape, for fields like `tool_use.input` whose
/// keys are tool-specific. Decodes any JSON; encodes back losslessly.
enum JSONValue: Decodable {
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

    /// Convenience accessor for table-driven tool summaries.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

/// One line of a Claude Code transcript JSONL.
///
/// Forgiving like `HookEvent`: unknown `type`s and unknown content block
/// types decode to an ignored case rather than throwing, since a transcript
/// is mostly line shapes Plume does not model.
struct TranscriptEntry: Decodable {
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
    let message: TranscriptMessage?
    let attachment: TranscriptAttachment?

    enum CodingKeys: String, CodingKey {
        case type, uuid, parentUuid, timestamp, isSidechain, agentId, cwd, gitBranch, effort, sessionId, message
        case attachment
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
        message = try container.decodeIfPresent(TranscriptMessage.self, forKey: .message)
        attachment = try container.decodeIfPresent(TranscriptAttachment.self, forKey: .attachment)

        if let raw = try container.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = TranscriptEntry.isoFormatter.date(from: raw)
        } else {
            timestamp = nil
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct TranscriptMessage: Decodable {
    let role: String?
    let model: String?
    let usage: TranscriptUsage?
    let content: TranscriptContent?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        usage = try container.decodeIfPresent(TranscriptUsage.self, forKey: .usage)
        content = try container.decodeIfPresent(TranscriptContent.self, forKey: .content)
    }

    enum CodingKeys: String, CodingKey {
        case role, model, usage, content
    }
}

struct TranscriptUsage: Decodable {
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
}

/// A message's `content` is either a bare string (plain user messages) or an
/// array of typed blocks (assistant messages, and user messages carrying
/// tool results).
struct TranscriptContent: Decodable {
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

/// A top-level `attachment` line's payload. Only `plan_mode` and
/// `plan_mode_exit` are modeled — both carry a `planFilePath` recording where
/// Claude Code intended to write the plan, whether or not it exists on disk
/// at the time the line was written.
struct TranscriptAttachment: Decodable {
    let planFilePath: String?

    private enum CodingKeys: String, CodingKey {
        case type, planFilePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "plan_mode", "plan_mode_exit":
            planFilePath = try container.decodeIfPresent(String.self, forKey: .planFilePath)
        default:
            planFilePath = nil
        }
    }
}

enum TranscriptBlock: Decodable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseId: String, content: String?)
    case ignored

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input
        case toolUseId = "tool_use_id"
        case content
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
            self = .toolResult(toolUseId: toolUseId, content: try TranscriptBlock.decodeResultContent(container))
        default:
            self = .ignored
        }
    }

    /// `tool_result.content` is a plain string, an array of blocks (only
    /// `text` is rendered, others are dropped), or absent entirely.
    private static func decodeResultContent(_ container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: .content) {
            return string
        }
        if let blocks = try? container.decodeIfPresent([TranscriptBlock].self, forKey: .content) {
            let text = blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
