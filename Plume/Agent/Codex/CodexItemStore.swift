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
    static let shared = CodexItemStore(cache: .shared)

    /// Lifecycle is carried separately from the item payload because some
    /// item types (notably agent messages) have no status field.
    enum ItemLifecycle {
        case snapshot
        case started
        case completed
    }

    private struct Items {
        var order: [String] = []
        var values: [String: JSONValue] = [:]
        var revision = 0
        var revisions: [String: Int] = [:]
        var historical: Set<String> = []
        var completed: Set<String> = []
        var cached: Set<String> = []
    }

    private var tabs: [UUID: Items] = [:]
    private let cache: CodexHistoryCache?
    private var threadIDs: [UUID: String] = [:]
    private var bindings: [UUID: UUID] = [:]
    private var hydratedTabs: Set<UUID> = []
    private var savedCopies: Set<UUID> = []
    private var restoredTabs: Set<UUID> = []
    @ObservationIgnored private var cacheWrites: [UUID: Task<Void, Never>] = [:]

    init(cache: CodexHistoryCache? = nil) { self.cache = cache }

    /// Only a mounted, persisted tab binds disk storage. Test sessions and
    /// child stores remain entirely in memory unless explicitly configured.
    func bind(tabID: UUID, threadID: String) {
        guard !threadID.isEmpty, threadIDs[tabID] != threadID else { return }
        if threadIDs[tabID] != nil {
            tabs.removeValue(forKey: tabID)
            hydratedTabs.remove(tabID)
            restoredTabs.remove(tabID)
            savedCopies.remove(tabID)
        }
        threadIDs[tabID] = threadID
        bindings[tabID] = UUID()
    }

    func isSavedCopy(forTab tabID: UUID) -> Bool { savedCopies.contains(tabID) }

    func restore(tabID: UUID, threadID: String) async {
        bind(tabID: tabID, threadID: threadID)
        guard let cache, !hydratedTabs.contains(tabID), let binding = bindings[tabID] else {
            persist(tabID: tabID)
            return
        }
        let snapshot = await cache.load(tabID: tabID, threadID: threadID)
        guard !Task.isCancelled, bindings[tabID] == binding, !hydratedTabs.contains(tabID) else { return }
        restoredTabs.insert(tabID)
        guard let snapshot else {
            persist(tabID: tabID)
            return
        }
        var current = tabs[tabID] ?? Items()
        var restoredOrder: [String] = []
        var restoredIDs = Set<String>()
        for entry in snapshot.entries {
            guard restoredIDs.insert(entry.stableID).inserted else { continue }
            restoredOrder.append(entry.stableID)
            // Any existing live/history value wins, including ones that
            // arrived before this async restore began.
            guard current.values[entry.stableID] == nil else { continue }
            current.values[entry.stableID] = normalized(entry.item, stableID: entry.stableID)
            current.cached.insert(entry.stableID)
            if entry.completed { current.completed.insert(entry.stableID) }
            if entry.historical { current.historical.insert(entry.stableID) }
        }
        current.order = restoredOrder + current.order.filter { !restoredIDs.contains($0) }
        tabs[tabID] = current
        if !current.cached.isEmpty { savedCopies.insert(tabID) }
        persist(tabID: tabID)
    }

    /// Called only after all authoritative history pages were received.
    func historyHydrated(tabID: UUID) {
        hydratedTabs.insert(tabID)
        savedCopies.remove(tabID)
        // Cached-only entries absent from the server no longer belong to its
        // authoritative transcript (for example after a rollback).
        if var items = tabs[tabID] {
            for key in items.cached {
                items.values.removeValue(forKey: key)
                items.completed.remove(key)
                items.historical.remove(key)
            }
            items.order.removeAll { items.cached.contains($0) }
            items.cached.removeAll()
            tabs[tabID] = items
        }
        persist(tabID: tabID)
    }

    func flush(tabID: UUID) async {
        await cacheWrites[tabID]?.value
        await cache?.flush(tabID: tabID)
    }

    private func persist(tabID: UUID) {
        guard let cache, let threadID = threadIDs[tabID], let items = tabs[tabID],
              restoredTabs.contains(tabID) || hydratedTabs.contains(tabID) else { return }
        let snapshot = CodexHistoryCache.Snapshot(threadID: threadID, entries: items.order.compactMap { key in
            guard let item = items.values[key] else { return nil }
            return .init(stableID: key, turnID: key.firstIndex(of: "#").map { String(key[..<$0]) }, item: item,
                         completed: items.completed.contains(key), historical: items.historical.contains(key))
        })
        let previous = cacheWrites[tabID]
        cacheWrites[tabID] = Task {
            await previous?.value
            await cache.schedule(tabID: tabID, snapshot: snapshot)
        }
    }

    struct PlanProposal: Equatable {
        let id: String
        let markdown: String
    }

    func replace(tabID: UUID, items: [JSONValue]) {
        var replacement = Items()
        for item in items { upsert(item, turnID: nil, lifecycle: .snapshot, into: &replacement) }
        tabs[tabID] = replacement
        persist(tabID: tabID)
    }

    func revision(forTab tabID: UUID) -> Int { tabs[tabID]?.revision ?? 0 }

    /// History pages contain `{item, turnId}` entries. Notifications can
    /// arrive while pages are loading; preserve those newer values and rows.
    func mergeHistory(tabID: UUID, entries: [JSONValue], since revision: Int) {
        let current = tabs[tabID] ?? Items()
        var page = Items()
        for entry in entries {
            let turnID = entry["turnId"]?.stringValue
            upsert(entry["item"] ?? entry, turnID: turnID, lifecycle: .snapshot, into: &page)
            if let id = entry["item"]?["id"]?.stringValue ?? entry["id"]?.stringValue {
                page.historical.insert(stableID(id, turnID: turnID))
            }
        }

        // Keep the live set and merge each page into it. This supports
        // incremental history paging and preserves notifications received
        // after the captured revision.
        var merged = current
        for id in page.order {
            guard let value = page.values[id] else { continue }
            if let rawID = value["id"]?.stringValue,
               let separator = rawID.firstIndex(of: "#") {
                let legacyID = String(rawID[rawID.index(after: separator)...])
                migrateLegacy(legacyID, to: id, in: &merged)
            }
            if let liveRevision = merged.revisions[id], liveRevision > revision {
                continue
            }
            if merged.values[id] == nil { insertHistorical(id, into: &merged) }
            merged.cached.remove(id)
            merged.values[id] = value
            merged.revisions[id] = revision
            merged.historical.insert(id)
            if page.completed.contains(id) { merged.completed.insert(id) }
        }
        tabs[tabID] = merged
        persist(tabID: tabID)
    }

    func upsert(tabID: UUID, item: JSONValue, turnID: String? = nil, lifecycle: ItemLifecycle = .snapshot) {
        var items = tabs[tabID] ?? Items()
        upsert(item, turnID: turnID, lifecycle: lifecycle, into: &items)
        tabs[tabID] = items
        persist(tabID: tabID)
    }

    func append(tabID: UUID, itemID: String, turnID: String? = nil, field: String, delta: String) {
        guard var items = tabs[tabID],
              let key = resolveKey(itemID, turnID: turnID, in: items),
              (!items.completed.contains(key) || items.cached.contains(key)),
              case .object(var object)? = items.values[key]
        else { return }
        object[field] = .string((object[field]?.stringValue ?? "") + delta)
        // `object["id"]` is already the resolved key; do not namespace it a
        // second time when a turn id was supplied for the lookup.
        upsert(.object(object), turnID: nil, lifecycle: .snapshot, into: &items)
        tabs[tabID] = items
        persist(tabID: tabID)
    }

    /// Stream directly into the row reserved by `item/started`, not the
    /// shared trailing-text overlay: tools may start before prose completes.
    func appendText(tabID: UUID, itemID: String, turnID: String? = nil, type: String, field: String, index: Int? = nil, delta: String) {
        guard !delta.isEmpty else { return }
        var items = tabs[tabID] ?? Items()
        let key = resolveKey(itemID, turnID: turnID, in: items) ?? stableID(itemID, turnID: turnID)
        guard !items.completed.contains(key) || items.cached.contains(key) else { return }
        var object: [String: JSONValue]
        if case .object(let existing)? = items.values[key] {
            object = existing
        } else {
            object = ["id": .string(key), "type": .string(type)]
        }
        if let index {
            guard index >= 0 else { return }
            var parts = object[field]?.arrayValue ?? []
            // Each part index comes from the server; avoid unbounded padding
            // on malformed input while retaining distinct summary paragraphs.
            guard index <= parts.count else { return }
            if index == parts.count { parts.append(.string("")) }
            parts[index] = .string((parts[index].stringValue ?? "") + delta)
            object[field] = .array(parts)
        } else {
            object[field] = .string((object[field]?.stringValue ?? "") + delta)
        }
        upsert(.object(object), turnID: nil, lifecycle: .snapshot, into: &items)
        tabs[tabID] = items
        persist(tabID: tabID)
    }

    func set(tabID: UUID, itemID: String, turnID: String? = nil, field: String, value: JSONValue) {
        guard var items = tabs[tabID],
              let key = resolveKey(itemID, turnID: turnID, in: items),
              (!items.completed.contains(key) || items.cached.contains(key)),
              case .object(var object)? = items.values[key]
        else { return }
        object[field] = value
        upsert(.object(object), turnID: nil, lifecycle: .snapshot, into: &items)
        tabs[tabID] = items
        persist(tabID: tabID)
    }

    func item(tabID: UUID, id: String) -> JSONValue? {
        guard let items = tabs[tabID], let key = resolveKey(id, turnID: nil, in: items) else { return nil }
        return items.values[key]
    }

    func fileChangeInput(tabID: UUID, itemID: String, turnID: String? = nil) -> [String: JSONValue] {
        guard let items = tabs[tabID],
              let key = resolveKey(itemID, turnID: turnID, in: items),
              let item = items.values[key]
        else { return [:] }
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

    func latestPendingPlan(forTab tabID: UUID) -> PlanProposal? {
        // A saved suffix may contain a later reply that settled a live plan.
        // Wait for authoritative history before offering any proposal action.
        guard !savedCopies.contains(tabID) else { return nil }
        guard let items = tabs[tabID] else { return nil }
        for id in items.order.indices.reversed() {
            let key = items.order[id]
            guard let item = items.values[key], !items.cached.contains(key) else { continue }
            // A later user turn means the proposal was already acted on.
            if item["type"]?.stringValue == "userMessage" { return nil }
            // History snapshots are settled by definition, even though the
            // plan item schema has no status field. Live proposals still wait
            // for `item/completed` before becoming actionable.
            guard (items.completed.contains(key) || items.historical.contains(key)),
                  item["type"]?.stringValue == "plan",
                  let markdown = item["text"]?.stringValue ?? item["proposed_plan"]?.stringValue,
                  !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return PlanProposal(id: key, markdown: markdown)
        }
        return nil
    }

    func forget(tabID: UUID) {
        // Archive/close clears live state while retaining offline history.
        tabs.removeValue(forKey: tabID)
        bindings.removeValue(forKey: tabID)
        threadIDs.removeValue(forKey: tabID)
        hydratedTabs.remove(tabID)
        restoredTabs.remove(tabID)
        savedCopies.remove(tabID)
    }

    private func upsert(_ item: JSONValue, turnID: String?, lifecycle: ItemLifecycle, into items: inout Items) {
        guard let id = item["id"]?.stringValue else { return }
        let key = stableID(id, turnID: turnID)
        if items.cached.remove(key) != nil {
            items.completed.remove(key)
            items.historical.remove(key)
        }
        if items.completed.contains(key), lifecycle != .completed { return }
        let normalized = normalized(item, stableID: key)
        let value: JSONValue
        if let existing = items.values[key] {
            switch lifecycle {
            case .started: value = mergeStarted(existing: existing, incoming: normalized)
            case .completed: value = mergeCompleted(existing: existing, incoming: normalized)
            case .snapshot: value = normalized
            }
        } else {
            value = normalized
        }
        if items.values[key] == nil { items.order.append(key) }
        items.values[key] = value
        items.revision += 1
        items.revisions[key] = items.revision
        if lifecycle == .completed || item["status"]?.stringValue == "completed" {
            items.completed.insert(key)
        }
    }

    private func resolveKey(_ itemID: String, turnID: String?, in items: Items) -> String? {
        let direct = stableID(itemID, turnID: turnID)
        if items.values[direct] != nil { return direct }
        guard turnID == nil else { return nil }
        let suffix = "#\(itemID)"
        let matches = items.order.filter { $0.hasSuffix(suffix) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func stableID(_ itemID: String, turnID: String?) -> String {
        guard let turnID, !turnID.isEmpty else { return itemID }
        return "\(turnID)#\(itemID)"
    }

    private func normalized(_ item: JSONValue, stableID: String) -> JSONValue {
        guard case .object(var object) = item else { return item }
        object["id"] = .string(stableID)
        return .object(object)
    }

    private func mergeStarted(existing: JSONValue, incoming: JSONValue) -> JSONValue {
        guard case .object(let old) = existing, case .object(var new) = incoming else { return incoming }
        for (key, value) in old {
            guard let current = new[key] else { new[key] = value; continue }
            if case .string(let currentText) = current,
               currentText.isEmpty,
               case .string(let oldText) = value,
               !oldText.isEmpty {
                new[key] = value
            } else if case .array(let currentArray) = current,
                      currentArray.isEmpty,
                      case .array(let oldArray) = value,
                      !oldArray.isEmpty {
                new[key] = value
            }
        }
        return .object(new)
    }

    private func mergeCompleted(existing: JSONValue, incoming: JSONValue) -> JSONValue {
        guard case .object(let old) = existing, case .object(var new) = incoming else { return incoming }
        for (key, value) in old where new[key] == nil { new[key] = value }
        return .object(new)
    }

    private func insertHistorical(_ id: String, into items: inout Items) {
        guard !items.order.contains(id) else { return }
        let firstLive = items.order.firstIndex { !items.historical.contains($0) }
        items.order.insert(id, at: firstLive ?? items.order.endIndex)
    }

    private func migrateLegacy(_ legacyID: String, to id: String, in items: inout Items) {
        guard legacyID != id,
              items.values[id] == nil,
              let value = items.values.removeValue(forKey: legacyID)
        else { return }
        if let index = items.order.firstIndex(of: legacyID) { items.order[index] = id }
        items.values[id] = normalized(value, stableID: id)
        items.revisions[id] = items.revisions.removeValue(forKey: legacyID)
        if items.historical.remove(legacyID) != nil { items.historical.insert(id) }
        if items.completed.remove(legacyID) != nil { items.completed.insert(id) }
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
        case "plan":
            let text = item["text"]?.stringValue ?? item["proposed_plan"]?.stringValue ?? ""
            return textMessage(
                id: id,
                role: .assistant,
                block: .markdown(text.isEmpty ? "" : "## Plan\n\n" + text)
            )
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
            // CodexSubagentStore renders this child in the shared subagent
            // surface. Keeping an inline notice as well duplicates every
            // lifecycle transition in the root conversation.
            return nil
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
            let output = CodexImageDecoder.extracting(item["result"] ?? item["error"])
            return call(id, "MCP", summary: "\(server).\(tool)", input: .json(pretty(item["arguments"])), result: prettyResult(output.text), images: output.images)
        case "dynamicToolCall":
            let namespace = item["namespace"]?.stringValue.map { "\($0)." } ?? ""
            let tool = item["tool"]?.stringValue ?? "Tool"
            let output = CodexImageDecoder.extracting(item["contentItems"])
            return call(id, tool, summary: namespace + tool, input: .json(pretty(item["arguments"])), result: prettyResult(output.text), images: output.images)
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
            let image = CodexImageDecoder.local(path)
            return call(id, "Read", summary: summarize("View image", (path as NSString).lastPathComponent), input: .json(pretty(.object(["path": .string(path)]))), result: image == nil ? "Image unavailable: \(path)" : nil, images: image.map { [$0] } ?? [])
        case "imageGeneration":
            let prompt = item["revisedPrompt"]?.stringValue ?? ""
            let image = CodexImageDecoder.inline(item["result"]?.stringValue) ?? CodexImageDecoder.local(item["savedPath"]?.stringValue)
            return call(id, "ImageGeneration", summary: "Generate image", input: .json(pretty(.object(["prompt": .string(prompt)]))), result: prettyResult(item["failure"]) ?? item["savedPath"]?.stringValue ?? (image == nil ? "Image unavailable" : nil), images: image.map { [$0] } ?? [])
        case "sleep":
            let duration = item["durationMs"]?.intValue ?? 0
            return call(id, "Wait", summary: "Wait(\(duration) ms)", input: .json("{}"), result: nil)
        default:
            return nil
        }
    }

    private static func call(_ id: String, _ name: String, summary: String, input: ToolCallInput, result: String?, images: [ChatImage] = []) -> ToolCall {
        let detail = summary == name ? nil : summary
        let detailStyle: ToolCallSummary.DetailStyle = ["Bash", "Edit", "Read"].contains(name) ? .code : .prose
        return ToolCall(
            id: id,
            name: name,
            summary: ToolCallSummary(name: name, detail: detail, detailStyle: detailStyle),
            input: input,
            result: result,
            resultImages: images
        )
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
            case "text":
                guard let text = value["text"]?.stringValue else { return nil }
                let kind = InjectedContent.classify(text: text, isMeta: false)
                return kind.isUserProse ? .markdown(kind.bodyText(text)) : .injected(kind, text: text)
            case "skill":
                let name = value["name"]?.stringValue ?? "Skill"
                return .injected(.skill(name: name), text: value["path"]?.stringValue ?? "")
            case "mention":
                return .injected(.systemNote, text: "Mention: \(value["name"]?.stringValue ?? value["path"]?.stringValue ?? "")")
            case "image":
                if let image = CodexImageDecoder.url(value["url"]?.stringValue) { return .image(image) }
                let url = value["url"]?.stringValue ?? ""
                return .injected(.systemNote, text: url.hasPrefix("data:") ? "Image could not be decoded" : "Image unavailable: \(url)")
            case "localImage":
                if let image = CodexImageDecoder.local(value["path"]?.stringValue) { return .image(image) }
                return .injected(.systemNote, text: "Image unavailable: \(value["path"]?.stringValue ?? "unknown path")")
            case "audio":
                return .injected(.systemNote, text: value["url"]?.stringValue ?? "Attachment")
            case "localAudio":
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
