import Foundation
import Observation

/// Codex child threads discovered through a parent conversation.
///
/// Child traffic shares the parent's app-server connection, but it is a
/// separate conversation. This store gives every child its own item table so
/// those events can never leak into the root chat.
@MainActor
@Observable
final class CodexSubagentStore {
    static let shared = CodexSubagentStore()

    private struct Child {
        let storeID: UUID
        var path: String?
        var descriptor: SubagentDescriptor?
        var status: TaskStatus
        var modifiedAt: Date?
        var hydrationError: String?
        var revision: Int
        var hasLiveLifecycle: Bool
    }

    private let items = CodexItemStore()
    private let statusEngine: StatusEngine
    private let completionTracker: SubagentCompletionTracker
    private let statusOverrides: SubagentStatusOverrides
    private var children: [UUID: [String: Child]] = [:]
    private var taskIDs: [UUID: UUID] = [:]

    init(
        statusEngine: StatusEngine = .shared,
        completionTracker: SubagentCompletionTracker = .shared,
        statusOverrides: SubagentStatusOverrides = .shared
    ) {
        self.statusEngine = statusEngine
        self.completionTracker = completionTracker
        self.statusOverrides = statusOverrides
    }

    func subagents(forTab tabID: UUID) -> [SubagentTranscript] {
        let values = (children[tabID] ?? [:]).map { threadID, child in
            var transcript = items.transcript(forTab: child.storeID) ?? Transcript()
            transcript.model = child.descriptor?.model
            transcript.sessionID = threadID
            if let error = child.hydrationError, transcript.messages.isEmpty {
                transcript.messages = [ChatMessage(
                    id: "codex-history-error-\(threadID)", role: .notice,
                    blocks: [.notice(ChatNotice(kind: .error, title: "Could not load subagent history", detail: error))],
                    timestamp: nil
                )]
            }
            return SubagentTranscript(
                id: threadID,
                transcript: transcript,
                modifiedAt: child.modifiedAt,
                descriptor: child.descriptor,
                status: child.status,
                provider: .codex
            )
        }
        return statusOverrides.applying(values, tabID: tabID).sorted {
            ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
        }
    }

    /// Returns every child thread ID referenced by this parent item. Hydration
    /// is deduplicated by the session rather than by this shared store: after
    /// reconnect, cached children still need a fresh read for offline work.
    @discardableResult
    func receiveParentItem(tabID: UUID, taskID: UUID, item: JSONValue, historical: Bool = false) -> [String] {
        taskIDs[tabID] = taskID
        switch item["type"]?.stringValue {
        case "subAgentActivity": receiveActivity(tabID: tabID, item: item, historical: historical)
        case "collabAgentToolCall": receiveLegacyCall(tabID: tabID, item: item, historical: historical)
        default: break
        }
        publish(tabID: tabID)
        switch item["type"]?.stringValue {
        case "subAgentActivity":
            return item["agentThreadId"]?.stringValue.map { [$0] } ?? []
        case "collabAgentToolCall":
            let receivers = item["receiverThreadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let stateIDs = item["agentsStates"]?.objectValue?.keys.map { $0 } ?? []
            return Array(Set(receivers + stateIDs))
        default:
            return []
        }
    }

    func receiveChildItem(tabID: UUID, threadID: String, item: JSONValue, turnID: String?, lifecycle: CodexItemStore.ItemLifecycle) {
        let storeID = ensure(tabID: tabID, threadID: threadID).storeID
        items.upsert(tabID: storeID, item: item, turnID: turnID, lifecycle: lifecycle)
        touch(tabID: tabID, threadID: threadID)
    }

    func appendText(tabID: UUID, threadID: String, itemID: String, turnID: String?, type: String, field: String, index: Int? = nil, delta: String) {
        let storeID = ensure(tabID: tabID, threadID: threadID).storeID
        items.appendText(tabID: storeID, itemID: itemID, turnID: turnID, type: type, field: field, index: index, delta: delta)
        touch(tabID: tabID, threadID: threadID)
    }

    func append(tabID: UUID, threadID: String, itemID: String, turnID: String?, field: String, delta: String) {
        let storeID = ensure(tabID: tabID, threadID: threadID).storeID
        items.append(tabID: storeID, itemID: itemID, turnID: turnID, field: field, delta: delta)
        touch(tabID: tabID, threadID: threadID)
    }

    func set(tabID: UUID, threadID: String, itemID: String, turnID: String?, field: String, value: JSONValue) {
        let storeID = ensure(tabID: tabID, threadID: threadID).storeID
        items.set(tabID: storeID, itemID: itemID, turnID: turnID, field: field, value: value)
        touch(tabID: tabID, threadID: threadID)
    }

    func mergeHistory(tabID: UUID, threadID: String, entries: [JSONValue], since revision: Int) {
        let storeID = ensure(tabID: tabID, threadID: threadID).storeID
        items.mergeHistory(tabID: storeID, entries: entries, since: revision)
        update(tabID: tabID, threadID: threadID) { $0.hydrationError = nil }
        publish(tabID: tabID)
    }

    func revision(tabID: UUID, threadID: String) -> Int {
        items.revision(forTab: ensure(tabID: tabID, threadID: threadID).storeID)
    }

    func lifecycleRevision(tabID: UUID, threadID: String) -> Int {
        ensure(tabID: tabID, threadID: threadID).revision
    }

    func receiveThreadMetadata(tabID: UUID, threadID: String, thread: JSONValue, since revision: Int? = nil) {
        update(tabID: tabID, threadID: threadID, advanceRevision: revision == nil) { child in
            if let source = thread["source"]?["subAgent"]?["thread_spawn"] {
                child.path = child.path ?? Self.agentPath(source["agent_path"])
                var descriptor = child.descriptor ?? SubagentDescriptor()
                descriptor.agentType = descriptor.agentType ?? thread["agentRole"]?.stringValue ?? source["agent_role"]?.stringValue ?? child.path
                descriptor.description = descriptor.description ?? thread["agentNickname"]?.stringValue ?? source["agent_nickname"]?.stringValue
                descriptor.model = descriptor.model ?? thread["model"]?.stringValue
                child.descriptor = descriptor.isEmpty ? nil : descriptor
            }
            if revision == nil || child.revision <= revision! {
                child.status = Self.threadStatus(thread["status"], fallback: child.status)
            }
            if revision == nil { child.hasLiveLifecycle = true }
        }
        publish(tabID: tabID)
    }

    func hydrationFailed(tabID: UUID, threadID: String, error: Error) {
        update(tabID: tabID, threadID: threadID) { $0.hydrationError = error.localizedDescription }
        publish(tabID: tabID)
    }

    func receiveTurnLifecycle(tabID: UUID, threadID: String, working: Bool, status: String? = nil) {
        update(tabID: tabID, threadID: threadID) { child in
            child.status = working ? .working : Self.status(status, fallback: .done)
            child.hasLiveLifecycle = true
        }
        publish(tabID: tabID)
    }

    func setOverride(_ override: SubagentStatusOverrides.Override?, tabID: UUID, subagentID: String) {
        statusOverrides.set(override, tabID: tabID, subagentID: subagentID)
        publish(tabID: tabID)
    }

    /// The owning app-server is gone. Keep readable transcripts, but release
    /// activity holds until a fresh live thread status confirms more work.
    func connectionClosed(tabID: UUID) {
        let threadIDs = children[tabID]?.keys.map { $0 } ?? []
        for threadID in threadIDs {
            update(tabID: tabID, threadID: threadID) { child in
                if child.status == .working { child.status = .interrupted }
                child.hasLiveLifecycle = true
            }
        }
        publish(tabID: tabID)
    }

    func forget(tabID: UUID) {
        let forgotten = children.removeValue(forKey: tabID)?.values.map { $0 } ?? []
        for child in forgotten { items.forget(tabID: child.storeID) }
        taskIDs.removeValue(forKey: tabID)
        statusEngine.setSubagentActivity(tabID: tabID, working: false)
    }

    private func receiveActivity(tabID: UUID, item: JSONValue, historical: Bool) {
        guard let threadID = item["agentThreadId"]?.stringValue else { return }
        update(tabID: tabID, threadID: threadID) { child in
            child.path = item["agentPath"]?.stringValue ?? child.path
            if child.descriptor == nil, let path = child.path {
                child.descriptor = SubagentDescriptor(agentType: path)
            }
            if !historical || !child.hasLiveLifecycle {
                switch item["kind"]?.stringValue {
                case "started", "interacted":
                    if !historical { child.status = .working }
                case "interrupted": child.status = .interrupted
                case "completed": child.status = .done
                default: break
                }
            }
            if !historical { child.hasLiveLifecycle = true }
        }
    }

    private func receiveLegacyCall(tabID: UUID, item: JSONValue, historical: Bool) {
        let receivers = item["receiverThreadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let stateIDs = item["agentsStates"]?.objectValue?.keys.map { $0 } ?? []
        for threadID in Set(receivers + stateIDs) {
            update(tabID: tabID, threadID: threadID) { child in
                var descriptor = child.descriptor ?? SubagentDescriptor()
                descriptor.description = descriptor.description ?? item["prompt"]?.stringValue
                descriptor.model = descriptor.model ?? item["model"]?.stringValue
                descriptor.toolUseID = descriptor.toolUseID ?? item["id"]?.stringValue
                child.descriptor = descriptor.isEmpty ? nil : descriptor
                if !historical || !child.hasLiveLifecycle {
                    let status = Self.status(item["agentsStates"]?[threadID]?["status"]?.stringValue, fallback: child.status)
                    if !historical || status != .working { child.status = status }
                }
                if !historical { child.hasLiveLifecycle = true }
            }
        }
    }

    private static func status(_ raw: String?, fallback: TaskStatus) -> TaskStatus {
        switch raw {
        case "pendingInit", "running": .working
        case "completed": .done
        case "interrupted": .interrupted
        case "shutdown": .interrupted
        case "failed", "error", "errored", "notFound": .error
        default: fallback
        }
    }

    private static func threadStatus(_ value: JSONValue?, fallback: TaskStatus) -> TaskStatus {
        switch value?["type"]?.stringValue ?? value?.stringValue {
        case "active": .working
        case "idle": .done
        case "systemError": .error
        case "notLoaded":
            switch fallback {
            case .done, .error, .interrupted: fallback
            default: .interrupted
            }
        default: fallback
        }
    }

    private static func agentPath(_ value: JSONValue?) -> String? {
        value?.stringValue ?? value?.arrayValue?.compactMap(\.stringValue).joined(separator: "/")
    }

    @discardableResult private func ensure(tabID: UUID, threadID: String) -> Child {
        if let child = children[tabID]?[threadID] { return child }
        let child = Child(storeID: UUID(), path: nil, descriptor: nil, status: .notStarted, modifiedAt: nil, hydrationError: nil, revision: 0, hasLiveLifecycle: false)
        children[tabID, default: [:]][threadID] = child
        return child
    }

    private func update(tabID: UUID, threadID: String, advanceRevision: Bool = true, body: (inout Child) -> Void) {
        var child = ensure(tabID: tabID, threadID: threadID)
        body(&child)
        if advanceRevision { child.revision += 1 }
        child.modifiedAt = .now
        children[tabID, default: [:]][threadID] = child
    }

    private func touch(tabID: UUID, threadID: String) {
        update(tabID: tabID, threadID: threadID) { child in
            if child.status == .notStarted { child.status = .working }
            child.hasLiveLifecycle = true
        }
        publish(tabID: tabID)
    }

    private func publish(tabID: UUID) {
        let subagents = subagents(forTab: tabID)
        completionTracker.observe(subagents, tabID: tabID)
        statusEngine.setSubagentActivity(tabID: tabID, working: subagents.contains { $0.status == .working })
    }
}
