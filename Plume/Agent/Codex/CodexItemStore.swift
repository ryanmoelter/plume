import Foundation
import Observation

/// Live and historical Codex items, indexed by the stable item id.
///
/// Codex's typed item fields are mapped directly to Plume's provider-neutral
/// chat model. They must not pass through `ToolCallSummary`,
/// `ToolCallInputRendering`, `FileDiffBuilder`, or
/// `InteractiveToolPayload.decoding`: those describe Claude Code's tool JSON.
@MainActor
@Observable
final class CodexItemStore {
    static let shared = CodexItemStore()

    private struct Items {
        var order: [String] = []
        var values: [String: JSONValue] = [:]
    }

    private var tabs: [UUID: Items] = [:]

    func replace(tabID: UUID, items: [JSONValue]) {
        var replacement = Items()
        for item in items { upsert(item, into: &replacement) }
        tabs[tabID] = replacement
    }

    func upsert(tabID: UUID, item: JSONValue) {
        var items = tabs[tabID] ?? Items()
        upsert(item, into: &items)
        tabs[tabID] = items
    }

    func append(tabID: UUID, itemID: String, field: String, delta: String) {
        guard var items = tabs[tabID],
              case .object(var object)? = items.values[itemID]
        else { return }
        object[field] = .string((object[field]?.stringValue ?? "") + delta)
        items.values[itemID] = .object(object)
        tabs[tabID] = items
    }

    func set(tabID: UUID, itemID: String, field: String, value: JSONValue) {
        guard var items = tabs[tabID],
              case .object(var object)? = items.values[itemID]
        else { return }
        object[field] = value
        items.values[itemID] = .object(object)
        tabs[tabID] = items
    }

    func item(tabID: UUID, id: String) -> JSONValue? {
        tabs[tabID]?.values[id]
    }

    func fileChangeInput(tabID: UUID, itemID: String) -> [String: JSONValue] {
        guard let item = item(tabID: tabID, id: itemID) else { return [:] }
        let changes = item["changes"]?.arrayValue ?? []
        let patches = changes.compactMap { change -> JSONValue? in
            guard let path = change["path"]?.stringValue,
                  let diff = change["diff"]?.stringValue
            else { return nil }
            return .object(["path": .string(path), "diff": .string(diff)])
        }
        return patches.isEmpty ? [:] : ["changes": .array(patches)]
    }

    func transcript(forTab tabID: UUID) -> Transcript? {
        guard let items = tabs[tabID] else { return nil }
        let messages = items.order.compactMap { id in
            items.values[id].flatMap(Self.message)
        }
        return Transcript(messages: messages)
    }

    func forget(tabID: UUID) {
        tabs.removeValue(forKey: tabID)
    }

    private func upsert(_ item: JSONValue, into items: inout Items) {
        guard let id = item["id"]?.stringValue else { return }
        if items.values[id] == nil { items.order.append(id) }
        items.values[id] = item
    }

    private static func message(_ item: JSONValue) -> ChatMessage? {
        guard let id = item["id"]?.stringValue,
              let type = item["type"]?.stringValue
        else { return nil }

        switch type {
        case "userMessage":
            let blocks = userBlocks(item["content"]?.arrayValue ?? [])
            guard !blocks.isEmpty else { return nil }
            return ChatMessage(id: id, role: .user, blocks: blocks, timestamp: nil)
        case "agentMessage":
            return textMessage(id: id, role: .assistant, block: .markdown(item["text"]?.stringValue ?? ""))
        case "reasoning":
            let summary = strings(item["summary"]).joined(separator: "\n")
            let content = strings(item["content"]).joined(separator: "\n")
            return textMessage(id: id, role: .assistant, block: .thinking(summary.isEmpty ? content : summary))
        case "contextCompaction":
            return notice(id: id, kind: .compaction, title: "Conversation compacted")
        case "enteredReviewMode":
            return notice(id: id, kind: .info, title: "Entered review mode", detail: item["review"]?.stringValue)
        case "exitedReviewMode":
            return notice(id: id, kind: .info, title: "Exited review mode", detail: item["review"]?.stringValue)
        case "hookPrompt":
            let detail = (item["fragments"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            return notice(id: id, kind: .info, title: "Hook prompt", detail: detail)
        case "subAgentActivity":
            let kind = item["kind"]?.stringValue ?? "updated"
            return notice(id: id, kind: .info, title: "Subagent \(kind)", detail: item["agentPath"]?.stringValue)
        default:
            guard let call = toolCall(item, type: type, id: id) else { return nil }
            return ChatMessage(id: id, role: .assistant, blocks: [.toolCall(call)], timestamp: nil)
        }
    }

    private static func toolCall(_ item: JSONValue, type: String, id: String) -> ToolCall? {
        switch type {
        case "commandExecution":
            let command = item["command"]?.stringValue ?? ""
            let exit = item["exitCode"]?.intValue.map { "Exit code \($0)" }
            return call(id, "Bash", summary: summarize("Bash", command), input: .code(language: "sh", text: command), result: joined(exit, item["aggregatedOutput"]?.stringValue))
        case "fileChange":
            let changes = item["changes"]?.arrayValue ?? []
            let blocks = changes.map { change -> FileDiff in
                UnifiedDiffParser.parse(change["diff"]?.stringValue ?? "", path: change["path"]?.stringValue)
            }
            let combined = FileDiff(
                path: blocks.count == 1 ? blocks.first?.path : nil,
                lines: Array(blocks.flatMap(\.lines).prefix(FileDiffBuilder.maxRenderedLines)),
                truncatedLineCount: max(0, blocks.reduce(0) { $0 + $1.lines.count + $1.truncatedLineCount } - FileDiffBuilder.maxRenderedLines)
            )
            let paths = changes.compactMap { $0["path"]?.stringValue }.joined(separator: ", ")
            return call(id, "Edit", summary: summarize("Edit", paths), input: .diff(combined), result: item["status"]?.stringValue)
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? "MCP"
            let tool = item["tool"]?.stringValue ?? "tool"
            return call(id, "MCP", summary: "\(server).\(tool)", input: .json(pretty(item["arguments"])), result: prettyResult(item["result"] ?? item["error"]))
        case "dynamicToolCall":
            let namespace = item["namespace"]?.stringValue.map { "\($0)." } ?? ""
            let tool = item["tool"]?.stringValue ?? "Tool"
            return call(id, tool, summary: namespace + tool, input: .json(pretty(item["arguments"])), result: prettyResult(item["contentItems"]))
        case "collabAgentToolCall":
            let tool = item["tool"]?.stringValue ?? "Agent"
            return call(id, "Agent", summary: "Agent(\(tool))", input: .json(pretty(item["prompt"])), result: prettyResult(item["agentsStates"] ?? item["status"]))
        case "webSearch":
            let query = item["query"]?.stringValue ?? ""
            return call(id, "WebSearch", summary: summarize("WebSearch", query), input: .json(pretty(item["action"])), result: prettyResult(item["results"]))
        case "plan":
            return call(id, "Plan", summary: "Plan", input: .json("{}"), result: item["text"]?.stringValue)
        case "functionCallOutput":
            let name = item["name"]?.stringValue ?? "Function output"
            return call(id, name, summary: name, input: .json("{}"), result: prettyResult(item["output"]))
        case "imageView":
            let path = item["path"]?.stringValue ?? ""
            return call(id, "Read", summary: summarize("View image", (path as NSString).lastPathComponent), input: .json(pretty(.object(["path": .string(path)]))), result: nil)
        case "imageGeneration":
            let prompt = item["revisedPrompt"]?.stringValue ?? ""
            return call(id, "ImageGeneration", summary: "Generate image", input: .json(pretty(.object(["prompt": .string(prompt)]))), result: item["savedPath"]?.stringValue ?? item["result"]?.stringValue ?? prettyResult(item["failure"]))
        case "sleep":
            let duration = item["durationMs"]?.intValue ?? 0
            return call(id, "Wait", summary: "Wait(\(duration) ms)", input: .json("{}"), result: nil)
        default:
            return nil
        }
    }

    private static func call(_ id: String, _ name: String, summary: String, input: ToolCallInput, result: String?) -> ToolCall {
        ToolCall(id: id, name: name, summary: summary, input: input, result: result)
    }

    private static func textMessage(id: String, role: ChatMessage.Role, block: ChatBlock) -> ChatMessage? {
        switch block {
        case .markdown(let text) where text.isEmpty: return nil
        case .thinking(let text) where text.isEmpty: return nil
        default: return ChatMessage(id: id, role: role, blocks: [block], timestamp: nil)
        }
    }

    private static func notice(id: String, kind: ChatNotice.Kind, title: String, detail: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: .notice, blocks: [.notice(.init(kind: kind, title: title, detail: detail))], timestamp: nil)
    }

    private static func userBlocks(_ content: [JSONValue]) -> [ChatBlock] {
        content.compactMap { value in
            switch value["type"]?.stringValue {
            case "text": return value["text"]?.stringValue.map(ChatBlock.markdown)
            case "skill":
                let name = value["name"]?.stringValue ?? "Skill"
                return .injected(.skill(name: name), text: value["path"]?.stringValue ?? "")
            case "mention":
                return .injected(.systemNote, text: "Mention: \(value["name"]?.stringValue ?? value["path"]?.stringValue ?? "")")
            case "image", "audio":
                return .injected(.systemNote, text: value["url"]?.stringValue ?? "Attachment")
            case "localImage", "localAudio":
                return .injected(.systemNote, text: value["path"]?.stringValue ?? "Attachment")
            default: return nil
            }
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func summarize(_ name: String, _ detail: String) -> String {
        let line = detail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? detail
        guard !line.isEmpty else { return name }
        return "\(name)(\(line.count > 60 ? String(line.prefix(60)) + "…" : line))"
    }

    private static func joined(_ first: String?, _ second: String?) -> String? {
        [first, second].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n").nonEmpty
    }

    private static func prettyResult(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        return pretty(value).nonEmpty
    }

    private static func pretty(_ value: JSONValue?) -> String {
        guard let value,
              let data = try? JSONEncoder.pretty.encode(value)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
