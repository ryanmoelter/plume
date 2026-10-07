import Foundation
import Observation

/// Background tasks still running per tab, so the Mac stays awake for work
/// that outlives the turn that started it.
///
/// A `Monitor`, a backgrounded `Bash` and a `Workflow` all keep running after
/// the agent's turn ends. The tab drops to `awaitingReply` at that point, and
/// without this the Mac would sleep before the task ever fires.
///
/// Each tab has one of two sources, and both replace their entries wholesale
/// rather than counting up and down — a counter kept in step by hand would
/// eventually miss a release, which here means the Mac never sleeps again.
///
/// - A **live list** from the running process (`replaceLive`), which a
///   headless tab gets from the CLI's `background_tasks_changed` events. It
///   decides membership outright and has no time limit: a task is running for
///   exactly as long as the CLI lists it.
/// - **Inferred entries** (`replace`), read from the transcript for a
///   terminal tab or from a Codex inventory. They name an end only when the
///   task announced one, so `hardCap` bounds them.
///
/// A live tab's inferred entries still supply what the list lacks — the
/// list reports a `Monitor` as a plain command and gives no start time.
@MainActor
@Observable
final class BackgroundTaskTracker {
    static let shared = BackgroundTaskTracker()

    enum Kind: Equatable, Sendable {
        case monitor
        case backgroundCommand
        case workflow

        /// What a task of this kind is called when its call named nothing.
        var label: String {
            switch self {
            case .monitor: "Monitor"
            case .backgroundCommand: "Background"
            case .workflow: "Workflow"
            }
        }
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let id: String
        let kind: Kind
        /// What the call said the task was for, so two monitors in one tab
        /// are told apart. Nil when the call named nothing.
        let description: String?
        let startedAt: Date
        /// When the tool said it would stop, or nil when it declared no end.
        let expiresAt: Date?

        init(id: String, kind: Kind, description: String? = nil, startedAt: Date, expiresAt: Date?) {
            self.id = id
            self.kind = kind
            self.description = description
            self.startedAt = startedAt
            self.expiresAt = expiresAt
        }
    }

    /// No inferred entry may hold the Mac awake longer than this, whatever a
    /// task declared. A persistent monitor names no end, and a transcript that
    /// stops being written — the app quit mid-task, the CLI died — leaves its
    /// entries with nothing to clear them. A live list needs no cap, because
    /// its process reports every end and its exit clears the rest.
    static let hardCap: TimeInterval = 30 * 60

    private var entriesByTab: [UUID: [Entry]] = [:]
    /// A tab present here, even with an empty list, ignores its inferred
    /// entries for membership.
    private var liveEntriesByTab: [UUID: [Entry]] = [:]

    /// Bumped when an expiry passes, so a derived reason set recomputes
    /// without anything having written to the transcript.
    private var revision = 0

    @ObservationIgnored private var expiryTimer: Task<Void, Never>?

    init() {}

    func replace(tabID: UUID, entries: [Entry]) {
        if entries.isEmpty {
            guard entriesByTab[tabID] != nil else { return }
            entriesByTab.removeValue(forKey: tabID)
        } else {
            guard entriesByTab[tabID] != entries else { return }
            entriesByTab[tabID] = entries
        }
        armExpiryTimer()
    }

    /// Makes `entries` the tab's whole membership until `forget`. An empty
    /// list keeps the tab live, so a process that exited holds nothing even
    /// while its transcript still reads as mid-task.
    func replaceLive(tabID: UUID, entries: [Entry]) {
        let previous = Dictionary(
            (liveEntriesByTab[tabID] ?? []).map { ($0.id, $0.startedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let carried = entries.map { entry in
            guard let startedAt = previous[entry.id] else { return entry }
            return Entry(
                id: entry.id,
                kind: entry.kind,
                description: entry.description,
                startedAt: startedAt,
                expiresAt: entry.expiresAt
            )
        }
        guard liveEntriesByTab[tabID] != carried else { return }
        liveEntriesByTab[tabID] = carried
        armExpiryTimer()
    }

    func forget(tabID: UUID) {
        let removedInferred = entriesByTab.removeValue(forKey: tabID) != nil
        let removedLive = liveEntriesByTab.removeValue(forKey: tabID) != nil
        guard removedInferred || removedLive else { return }
        armExpiryTimer()
    }

    func reset() {
        entriesByTab.removeAll()
        liveEntriesByTab.removeAll()
        armExpiryTimer()
    }

    func inFlight(tabID: UUID, now: Date = Date()) -> [Entry] {
        _ = revision
        guard let live = liveEntriesByTab[tabID] else {
            return (entriesByTab[tabID] ?? []).filter { $0.isRunning(at: now) }
        }
        let inferred = Dictionary(
            (entriesByTab[tabID] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return live
            .map { $0.enriched(by: inferred[$0.id]) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Every tab with something still running, for the keep-awake reason set.
    ///
    /// One row per tab however many tasks it runs, so the description is the
    /// oldest running task's — the one the tab has been held awake for
    /// longest. `count` is how many are running.
    var tabsWithBackgroundTasks: [(tabID: UUID, kind: Kind, description: String?, count: Int)] {
        _ = revision
        let now = Date()
        return Set(entriesByTab.keys).union(liveEntriesByTab.keys).compactMap { tabID in
            let running = inFlight(tabID: tabID, now: now)
            guard let first = running.first else { return nil }
            return (tabID, first.kind, first.description, running.count)
        }
    }

    /// One sleep to the next deadline rather than a poll, because an idle
    /// interval timer costs main-thread work every tick for the hours a
    /// persistent monitor can run (see docs/handoff-idle-cpu.md).
    private func armExpiryTimer() {
        expiryTimer?.cancel()
        expiryTimer = nil
        let now = Date()
        let deadlines = entriesByTab
            .filter { liveEntriesByTab[$0.key] == nil }
            .values.flatMap { $0 }
            .filter { $0.isRunning(at: now) }
            .map(\.deadline)
        guard let next = deadlines.min() else { return }
        expiryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            self?.revision &+= 1
            self?.armExpiryTimer()
        }
    }
}

private extension BackgroundTaskTracker.Entry {
    /// The cap wins over a longer declaration, so a task that declares an
    /// hour still stops holding the Mac after thirty minutes.
    var deadline: Date {
        let capped = startedAt.addingTimeInterval(BackgroundTaskTracker.hardCap)
        guard let expiresAt else { return capped }
        return min(expiresAt, capped)
    }

    func isRunning(at now: Date) -> Bool {
        deadline > now
    }

    /// The live list reports a `Monitor` as a plain command and carries no
    /// start time, so the transcript's reading of the same id fills both in.
    func enriched(by inferred: Self?) -> Self {
        guard let inferred else { return self }
        return Self(
            id: id,
            kind: inferred.kind,
            description: description ?? inferred.description,
            startedAt: min(startedAt, inferred.startedAt),
            expiresAt: inferred.expiresAt
        )
    }
}
