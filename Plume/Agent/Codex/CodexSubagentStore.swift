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
    static let shared = CodexSubagentStore(cache: .shared)

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
    private let cache: CodexSubagentHistoryCache?
    private var parentThreadIDs: [UUID: String] = [:]
    private var bindings: [UUID: UUID] = [:]
    private var restoredTabs: Set<UUID> = []
    private var parentHydratedTabs: Set<UUID> = []
    private var verifiedChildren: [UUID: Set<String>] = [:]
    @ObservationIgnored private var cacheWrites: [UUID: Task<Void, Never>] = [:]

    init(
        statusEngine: StatusEngine = .shared,
        completionTracker: SubagentCompletionTracker = .shared,
        statusOverrides: SubagentStatusOverrides = .shared,
        cache: CodexSubagentHistoryCache? = nil
    ) {
        self.cache = cache
        self.statusEngine = statusEngine
        self.completionTracker = completionTracker
        self.statusOverrides = statusOverrides
    }

    /// Restore is independent of app-server startup and scoped to the parent
    /// conversation, never just a child's globally unique thread identifier.
    func restore(tabID: UUID, taskID: UUID, parentThreadID: String) async {
        guard !parentThreadID.isEmpty else { return }
        if let previous = parentThreadIDs[tabID], previous != parentThreadID { forget(tabID: tabID) }
        parentThreadIDs[tabID] = parentThreadID
        taskIDs[tabID] = taskID
        if bindings[tabID] == nil { bindings[tabID] = UUID() }
        guard let cache, let binding = bindings[tabID] else { return }
        let saved = await cache.load(tabID: tabID, parentThreadID: parentThreadID)
        guard !Task.isCancelled, bindings[tabID] == binding else { return }
        restoredTabs.insert(tabID)
        for savedChild in saved ?? [] {
            // If the authoritative parent was read first, only children it
            // still references are eligible; removed children stay removed.
            if parentHydratedTabs.contains(tabID), verifiedChildren[tabID]?.contains(savedChild.threadID) != true { continue }
            let existed = children[tabID]?[savedChild.threadID] != nil
            var child = ensure(tabID: tabID, threadID: savedChild.threadID, authoritative: false)
            child.path = child.path ?? savedChild.path
            var descriptor = child.descriptor ?? SubagentDescriptor()
            descriptor.description = descriptor.description ?? savedChild.description
            descriptor.agentType = descriptor.agentType ?? savedChild.agentType
            descriptor.toolUseID = descriptor.toolUseID ?? savedChild.toolUseID
            descriptor.model = descriptor.model ?? savedChild.model
            if !existed { descriptor.stoppedByUser = savedChild.stoppedByUser }
            child.descriptor = descriptor.isEmpty ? nil : descriptor
            child.modifiedAt = child.modifiedAt ?? savedChild.modifiedAt
            if !existed || (!child.hasLiveLifecycle && child.status == .notStarted) {
                child.status = Self.offlineStatus(savedChild.status)
                child.hasLiveLifecycle = false
            }
            children[tabID, default: [:]][savedChild.threadID] = child
            items.restoreSnapshot(tabID: child.storeID, snapshot: .init(threadID: savedChild.threadID, entries: savedChild.entries))
        }
        publish(tabID: tabID)
    }

    /// The parent transcript is authoritative for discovery. Child transcripts
    /// may still be loading and can independently retain their saved content.
    func parentHistoryHydrated(tabID: UUID) {
        parentHydratedTabs.insert(tabID)
        let valid = verifiedChildren[tabID] ?? []
        for id in children[tabID]?.keys.map({ $0 }) ?? [] where !valid.contains(id) {
            if let removed = children[tabID]?.removeValue(forKey: id) { items.forget(tabID: removed.storeID) }
        }
        publish(tabID: tabID)
    }

    func flush(tabID: UUID) async {
        await cacheWrites[tabID]?.value
        await cache?.flush(tabID: tabID)
    }

    private func persist(tabID: UUID) {
        guard let cache, let parentThreadID = parentThreadIDs[tabID], restoredTabs.contains(tabID) else { return }
        let snapshots = (children[tabID] ?? [:]).map { threadID, child in
            CodexSubagentHistoryCache.Child(
                threadID: threadID, path: child.path, description: child.descriptor?.description,
                agentType: child.descriptor?.agentType, toolUseID: child.descriptor?.toolUseID,
                model: child.descriptor?.model, stoppedByUser: child.descriptor?.stoppedByUser ?? false,
                status: Self.offlineStatus(child.status.rawValue).rawValue, modifiedAt: child.modifiedAt,
                entries: items.snapshot(tabID: child.storeID, threadID: threadID)?.entries ?? []
            )
        }.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.threadID < $1.threadID }
            return ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
        }
        let previous = cacheWrites[tabID]
        cacheWrites[tabID] = Task {
            await previous?.value
            await cache.schedule(tabID: tabID, parentThreadID: parentThreadID, children: snapshots)
        }
    }

    private static func offlineStatus(_ raw: String) -> TaskStatus {
        switch TaskStatus(rawValue: raw) {
        case .done: .done
        case .error: .error
        default: .interrupted
        }
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
            if $0.modifiedAt == $1.modifiedAt { return $0.id < $1.id }
            return ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
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
        items.historyHydrated(tabID: storeID)
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
            update(tabID: tabID, threadID: threadID, authoritative: false) { child in
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
        parentThreadIDs.removeValue(forKey: tabID)
        bindings.removeValue(forKey: tabID)
        restoredTabs.remove(tabID)
        parentHydratedTabs.remove(tabID)
        verifiedChildren.removeValue(forKey: tabID)
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

    @discardableResult private func ensure(tabID: UUID, threadID: String, authoritative: Bool = true) -> Child {
        if authoritative { verifiedChildren[tabID, default: []].insert(threadID) }
        if let child = children[tabID]?[threadID] { return child }
        let child = Child(storeID: UUID(), path: nil, descriptor: nil, status: .notStarted, modifiedAt: nil, hydrationError: nil, revision: 0, hasLiveLifecycle: false)
        children[tabID, default: [:]][threadID] = child
        return child
    }

    private func update(tabID: UUID, threadID: String, advanceRevision: Bool = true, authoritative: Bool = true, body: (inout Child) -> Void) {
        var child = ensure(tabID: tabID, threadID: threadID, authoritative: authoritative)
        body(&child)
        if advanceRevision { child.revision += 1 }
        child.modifiedAt = .now
        children[tabID, default: [:]][threadID] = child
    }

    private func touch(tabID: UUID, threadID: String) {
        update(tabID: tabID, threadID: threadID) { child in
            if child.status == .notStarted || !child.hasLiveLifecycle { child.status = .working }
            child.hasLiveLifecycle = true
        }
        publish(tabID: tabID)
    }

    private func publish(tabID: UUID) {
        let subagents = subagents(forTab: tabID)
        completionTracker.observe(subagents, tabID: tabID)
        statusEngine.setSubagentActivity(tabID: tabID, working: subagents.contains { $0.status == .working })
        persist(tabID: tabID)
    }
}
