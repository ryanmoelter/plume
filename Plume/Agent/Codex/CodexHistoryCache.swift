import Foundation

/// A bounded, best-effort transcript snapshot. The actor serializes reads,
/// atomic replacements and removal on its own executor, never the UI actor.
actor CodexHistoryCache {
    @MainActor static let shared = CodexHistoryCache(
        directory: AppPaths.applicationSupport.appending(path: "codex-history")
    )

    nonisolated struct Entry: Codable, Sendable, Equatable {
        let stableID: String
        let turnID: String?
        let item: JSONValue
        let completed: Bool
        let historical: Bool

        init(stableID: String, turnID: String? = nil, item: JSONValue,
             completed: Bool = false, historical: Bool = false) {
            self.stableID = stableID
            self.turnID = turnID
            self.item = item
            self.completed = completed
            self.historical = historical
        }
    }

    nonisolated struct Snapshot: Codable, Sendable, Equatable {
        static let currentVersion = 1
        let version: Int
        let threadID: String
        let entries: [Entry]

        init(threadID: String, entries: [Entry]) {
            version = Self.currentVersion
            self.threadID = threadID
            self.entries = entries
        }
    }

    nonisolated struct Limits: Sendable {
        var maximumEntries = 10_000
        var maximumFileBytes = 8 * 1_024 * 1_024
        var maximumFiles = 100
        var maximumTotalBytes = 128 * 1_024 * 1_024
    }

    private let directory: URL
    private let debounce: Duration
    private let limits: Limits
    private var pending: [UUID: Snapshot] = [:]
    private var revisions: [UUID: UUID] = [:]
    private var writes: [UUID: Task<Void, Never>] = [:]

    init(directory: URL, debounce: Duration = .milliseconds(300), limits: Limits = Limits()) {
        self.directory = directory
        self.debounce = debounce
        self.limits = limits
    }

    /// Returns pending content when available, so an explicit load never
    /// regresses to the previous disk snapshot during the debounce interval.
    /// A cache miss or incompatible/corrupt data is ordinary and nonfatal.
    func load(tabID: UUID, threadID: String) -> Snapshot? {
        if let snapshot = pending[tabID] {
            return snapshot.threadID == threadID ? bounded(snapshot)?.snapshot : nil
        }
        let url = file(tabID)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= max(0, limits.maximumFileBytes),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Snapshot.currentVersion,
              snapshot.threadID == threadID,
              snapshot.entries.count <= max(0, limits.maximumEntries)
        else { return nil }
        return snapshot
    }

    /// Coalesces streaming bursts; a new thread replaces this tab's old
    /// snapshot rather than appending to another conversation's history.
    func schedule(tabID: UUID, snapshot: Snapshot) {
        writes.removeValue(forKey: tabID)?.cancel()
        let revision = UUID()
        revisions[tabID] = revision
        pending[tabID] = snapshot
        let debounce = debounce
        writes[tabID] = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.commit(tabID: tabID, revision: revision)
        }
    }

    /// Flush is explicit for turn completion and orderly shutdown. Failures
    /// remain cache misses; they must never fail a conversation or block exit.
    func flush(tabID: UUID? = nil) {
        let ids = tabID.map { [$0] } ?? Array(pending.keys)
        for id in ids {
            writes.removeValue(forKey: id)?.cancel()
            guard let revision = revisions[id] else { continue }
            commit(tabID: id, revision: revision)
        }
    }

    /// Cancelling pending work before deleting prevents a late debounce from
    /// recreating a tab's cache after the user deletes its conversation.
    func remove(tabID: UUID) {
        writes.removeValue(forKey: tabID)?.cancel()
        revisions.removeValue(forKey: tabID)
        pending.removeValue(forKey: tabID)
        try? FileManager.default.removeItem(at: file(tabID))
    }

    private func file(_ tabID: UUID) -> URL {
        directory.appending(path: tabID.uuidString + ".json")
    }

    private func commit(tabID: UUID, revision: UUID) {
        guard revisions[tabID] == revision, let snapshot = pending[tabID] else { return }
        writes.removeValue(forKey: tabID)
        revisions.removeValue(forKey: tabID)
        pending.removeValue(forKey: tabID)
        guard let bounded = bounded(snapshot) else {
            // An unusably small configured budget must not preserve stale
            // content from an earlier thread under this tab's identifier.
            try? FileManager.default.removeItem(at: file(tabID))
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bounded.data.write(to: file(tabID), options: .atomic)
            trimDirectory(keeping: file(tabID))
        } catch {
            // Read-only disks, removed directories, and exhausted storage
            // degrade to no offline history; the live transcript is intact.
        }
    }

    /// Retain the newest whole items, preserving their order and raw fields.
    /// Never truncate markdown or a tool payload into invalid partial data.
    private func bounded(_ snapshot: Snapshot) -> (snapshot: Snapshot, data: Data)? {
        guard snapshot.version == Snapshot.currentVersion, !snapshot.threadID.isEmpty else { return nil }
        let entries = Array(snapshot.entries.suffix(max(0, limits.maximumEntries)))
        let budget = max(0, min(limits.maximumFileBytes, limits.maximumTotalBytes))
        let encoder = JSONEncoder()
        func encode(_ count: Int) -> (snapshot: Snapshot, data: Data)? {
            let value = Snapshot(threadID: snapshot.threadID, entries: Array(entries.suffix(count)))
            guard let data = try? encoder.encode(value), data.count <= budget else { return nil }
            return (value, data)
        }
        if let entire = encode(entries.count) { return entire }
        guard var best = encode(0) else { return nil }
        var low = 0, high = entries.count
        while low < high {
            let count = (low + high + 1) / 2
            if let candidate = encode(count) {
                best = candidate
                low = count
            } else {
                high = count - 1
            }
        }
        return best
    }

    private func trimDirectory(keeping newest: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var candidates: [(url: URL, size: Int, date: Date)] = files.compactMap { url in
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        candidates.sort {
            if $0.url == newest { return false }
            if $1.url == newest { return true }
            if $0.date == $1.date { return $0.url.lastPathComponent < $1.url.lastPathComponent }
            return $0.date < $1.date
        }
        var count = candidates.count
        var total = candidates.reduce(0) { $0 + $1.size }
        for candidate in candidates {
            guard count > max(0, limits.maximumFiles) || total > max(0, limits.maximumTotalBytes) else { break }
            do {
                try FileManager.default.removeItem(at: candidate.url)
                count -= 1
                total -= candidate.size
            } catch { }
        }
    }
}
