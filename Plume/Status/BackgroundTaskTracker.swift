import Foundation
import Observation

/// Background tasks still running per tab, so the Mac stays awake for work
/// that outlives the turn that started it.
///
/// A `Monitor`, a backgrounded `Bash` and a `Workflow` all keep running after
/// the agent's turn ends. The tab drops to `awaitingReply` at that point, and
/// without this the Mac would sleep before the task ever fires.
///
/// Entries are reconciled wholesale from the transcript rather than counted
/// up and down. A transcript read is the only thing that sees them, and a
/// counter kept in step by hand would eventually miss a release — which here
/// means the Mac never sleeps again.
@MainActor
@Observable
final class BackgroundTaskTracker {
    static let shared = BackgroundTaskTracker()

    enum Kind: Equatable, Sendable {
        case monitor
        case backgroundCommand
        case workflow
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let id: String
        let kind: Kind
        let startedAt: Date
        /// When the tool said it would stop, or nil when it declared no end.
        let expiresAt: Date?
    }

    /// Nothing may hold the Mac awake longer than this, whatever a task
    /// declared. A persistent monitor names no end, and a transcript that
    /// stops being written — the app quit mid-task, the CLI died — leaves its
    /// entries with nothing to clear them.
    static let hardCap: TimeInterval = 30 * 60

    private var entriesByTab: [UUID: [Entry]] = [:]

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

    func forget(tabID: UUID) {
        guard entriesByTab.removeValue(forKey: tabID) != nil else { return }
        armExpiryTimer()
    }

    func reset() {
        entriesByTab.removeAll()
        armExpiryTimer()
    }

    func inFlight(tabID: UUID, now: Date = Date()) -> [Entry] {
        _ = revision
        return (entriesByTab[tabID] ?? []).filter { $0.isRunning(at: now) }
    }

    /// Every tab with something still running, for the keep-awake reason set.
    var tabsWithBackgroundTasks: [(tabID: UUID, kind: Kind)] {
        _ = revision
        let now = Date()
        return entriesByTab.compactMap { tabID, entries in
            guard let first = entries.first(where: { $0.isRunning(at: now) }) else { return nil }
            return (tabID, first.kind)
        }
    }

    /// One sleep to the next deadline rather than a poll, because an idle
    /// interval timer costs main-thread work every tick for the hours a
    /// persistent monitor can run (see docs/handoff-idle-cpu.md).
    private func armExpiryTimer() {
        expiryTimer?.cancel()
        expiryTimer = nil
        let now = Date()
        let deadlines = entriesByTab.values.flatMap { $0 }
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
}
