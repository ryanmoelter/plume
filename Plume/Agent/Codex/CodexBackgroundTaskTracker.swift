import Foundation

/// Live background terminal inventories, including terminals owned by child
/// threads. Historical command items cannot tell us whether their process is
/// still alive, so only app-server's current inventory can acquire a hold.
@MainActor
final class CodexBackgroundTaskTracker {
    typealias Request = @MainActor (String, JSONValue) async throws -> JSONValue

    private let tabID: UUID
    private let tracker: BackgroundTaskTracker
    private let request: Request
    private let pollInterval: Duration
    private var entriesByThread: [String: [BackgroundTaskTracker.Entry]] = [:]
    private var refreshes: [String: Task<Void, Never>] = [:]
    private var polls: [String: Task<Void, Never>] = [:]
    private var dirty: Set<String> = []
    private var stopped = false

    init(tabID: UUID, tracker: BackgroundTaskTracker = .shared,
         pollInterval: Duration = .seconds(5), request: @escaping Request) {
        self.tabID = tabID
        self.tracker = tracker
        self.pollInterval = pollInterval
        self.request = request
    }

    /// Coalesces bursts of item events. An event during an outstanding read
    /// requests another inventory afterward, so a stale response cannot hide
    /// a command that started while that read was in flight.
    @discardableResult
    func refresh(threadID: String) -> Task<Void, Never>? {
        guard !stopped else { return nil }
        polls.removeValue(forKey: threadID)?.cancel()
        if let task = refreshes[threadID] {
            dirty.insert(threadID)
            return task
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                dirty.remove(threadID)
                await readInventory(threadID: threadID)
            } while !stopped && !Task.isCancelled && dirty.contains(threadID)
            refreshes.removeValue(forKey: threadID)
            schedulePoll(threadID: threadID)
        }
        refreshes[threadID] = task
        return task
    }

    func stop() {
        stopped = true
        for task in refreshes.values { task.cancel() }
        for task in polls.values { task.cancel() }
        refreshes.removeAll()
        polls.removeAll()
        dirty.removeAll()
        entriesByThread.removeAll()
        tracker.forget(tabID: tabID)
    }

    private func readInventory(threadID: String) async {
        do {
            var terminals: [JSONValue] = []
            var cursor: String?
            var cursors: Set<String> = []
            repeat {
                var params: [String: JSONValue] = ["threadId": .string(threadID), "limit": .number(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let result = try await request("thread/backgroundTerminals/list", .object(params))
                guard !stopped, !Task.isCancelled else { return }
                guard let page = result["data"]?.arrayValue else { return }
                terminals.append(contentsOf: page)
                cursor = result["nextCursor"]?.stringValue
                if let cursor, !cursors.insert(cursor).inserted { return }
            } while cursor != nil
            let previous = Dictionary((entriesByThread[threadID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let now = Date()
            var inventory: [String: BackgroundTaskTracker.Entry] = [:]
            for terminal in terminals {
                guard let processID = terminal["processId"]?.stringValue else { continue }
                let id = "\(threadID)/\(processID)"
                inventory[id] = previous[id] ?? BackgroundTaskTracker.Entry(
                    id: id, kind: .backgroundCommand, startedAt: now, expiresAt: nil
                )
            }
            entriesByThread[threadID] = inventory.values.sorted { $0.id < $1.id }
            publish()
        } catch {
            // Unsupported older servers acquire no hold. Transient failures
            // retain existing entries, whose original hard-cap deadline still
            // applies; failed polling must never renew that deadline.
        }
    }

    private func publish() {
        tracker.replace(tabID: tabID, entries: entriesByThread.values.flatMap { $0 }.sorted { $0.id < $1.id })
    }

    private func schedulePoll(threadID: String) {
        guard !stopped, !Task.isCancelled,
              entriesByThread[threadID]?.contains(where: {
                  $0.startedAt.addingTimeInterval(BackgroundTaskTracker.hardCap) > Date()
              }) == true else { return }
        let interval = pollInterval
        polls[threadID] = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh(threadID: threadID)
        }
    }
}
