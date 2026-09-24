import Foundation

/// Child history shares the root cache's byte/file budgets and atomic actor
/// I/O, in a separate directory. Each retained item carries child metadata so
/// pruning an old prefix never leaves a transcript without its identity.
actor CodexSubagentHistoryCache {
    @MainActor static let shared = CodexSubagentHistoryCache(
        directory: AppPaths.applicationSupport.appending(path: "codex-subagent-history")
    )

    nonisolated struct Child: Codable, Sendable, Equatable {
        var threadID: String
        var path: String?
        var description: String?
        var agentType: String?
        var toolUseID: String?
        var model: String?
        var stoppedByUser: Bool = false
        var status: String
        var modifiedAt: Date?
        var entries: [CodexHistoryCache.Entry] = []
    }
    private nonisolated struct Record: Codable {
        let child: Child
        let entry: CodexHistoryCache.Entry?
    }

    private let storage: CodexHistoryCache
    init(directory: URL, debounce: Duration = .milliseconds(300), limits: CodexHistoryCache.Limits = .init()) {
        storage = CodexHistoryCache(directory: directory, debounce: debounce, limits: limits)
    }

    func schedule(tabID: UUID, parentThreadID: String, children: [Child]) async {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var records: [CodexHistoryCache.Entry] = []
        for child in children {
            var metadata = child
            metadata.entries = []
            let entries: [CodexHistoryCache.Entry?] = child.entries.isEmpty ? [nil] : child.entries.map { $0 }
            for (index, entry) in entries.enumerated() {
                guard let data = try? encoder.encode(Record(child: metadata, entry: entry)),
                      let value = try? decoder.decode(JSONValue.self, from: data) else { continue }
                records.append(.init(stableID: "\(child.threadID)/\(index)", item: value))
            }
        }
        await storage.schedule(tabID: tabID, snapshot: .init(threadID: parentThreadID, entries: records))
    }

    func load(tabID: UUID, parentThreadID: String) async -> [Child]? {
        guard let snapshot = await storage.load(tabID: tabID, threadID: parentThreadID) else { return nil }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var order: [String] = []
        var children: [String: Child] = [:]
        for record in snapshot.entries {
            guard let data = try? encoder.encode(record.item),
                  let value = try? decoder.decode(Record.self, from: data),
                  !value.child.threadID.isEmpty else { return nil }
            if children[value.child.threadID] == nil {
                order.append(value.child.threadID)
                var child = value.child
                child.entries = []
                children[child.threadID] = child
            }
            if let entry = value.entry { children[value.child.threadID]?.entries.append(entry) }
        }
        return order.compactMap { children[$0] }
    }

    func flush(tabID: UUID) async { await storage.flush(tabID: tabID) }
    func remove(tabID: UUID) async { await storage.remove(tabID: tabID) }
}
