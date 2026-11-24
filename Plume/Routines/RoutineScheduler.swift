import AppKit
import Foundation
import Observation
import os
import SwiftData

/// Runs routines when they come due: on a timer, on wake and at launch. Each
/// routine's latest run lives here in memory, with its error if it failed.
@MainActor
@Observable
final class RoutineScheduler {
    static let shared = RoutineScheduler()

    nonisolated struct LastRun: Equatable, Sendable {
        var startedAt: Date
        var error: String?
        var taskID: UUID?
        var tabID: UUID?
    }

    private(set) var lastRuns: [UUID: LastRun] = [:]
    private(set) var startingIDs: Set<UUID> = []

    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var calendar: () -> Calendar = { .current }
    /// The store a window has finished setting up. A run started before that
    /// would miss the callbacks the window installs to persist session IDs.
    @ObservationIgnored var context: () -> ModelContext? = { CLICommandHandler.shared.frontmostWindow?.context }
    @ObservationIgnored var startRun: @MainActor (Routine, ModelContext) async throws -> WorkTask = { try await RoutineRunner.start($0, in: $1) }
    @ObservationIgnored var notifier: Notifier = .shared

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var launchTick: Task<Void, Never>?
    /// Tab ID to routine name, for the runs that notify on finish.
    @ObservationIgnored private var watchedTabs: [UUID: String] = [:]

    static let tickInterval: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { RoutineScheduler.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RoutineScheduler.shared.tick() }
        }
        StatusEngine.shared.setTabStatusObserver("RoutineScheduler") { [weak self] _, tabID, status, _ in
            self?.tabStatusChanged(tabID: tabID, status: status)
        }
        launchTick = Task { [weak self] in
            while self?.context() == nil {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.tick()
        }
    }

    /// Starts every routine due at `now`, and returns their IDs.
    @discardableResult
    func tick(now override: Date? = nil) -> [UUID] {
        guard let context = context() else { return [] }
        let now = override ?? now()
        let calendar = calendar()
        let routines = (try? context.fetch(FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.orderIndex)]))) ?? []
        let due = routines.filter { !startingIDs.contains($0.id) && $0.isDue(now: now, calendar: calendar) }
        for routine in due {
            beginRun(routine, at: now, in: context)
        }
        return due.map(\.id)
    }

    /// Runs `routine` now, whether or not it's due. False when it is already
    /// starting or no window is ready.
    @discardableResult
    func runNow(_ routine: Routine) -> Bool {
        guard let context = context(), !startingIDs.contains(routine.id) else { return false }
        beginRun(routine, at: now(), in: context)
        return true
    }

    /// Awaits the run, for a caller that reports its outcome.
    func runNowAndWait(_ routine: Routine) async -> LastRun? {
        guard let context = context(), !startingIDs.contains(routine.id) else { return nil }
        let id = routine.id
        await run(begin(routine, at: now()), in: context)
        return lastRuns[id]
    }

    func isStarting(_ id: UUID) -> Bool { startingIDs.contains(id) }

    private func beginRun(_ routine: Routine, at now: Date, in context: ModelContext) {
        let started = begin(routine, at: now)
        Task { await run(started, in: context) }
    }

    /// Records the run before anything awaits, so a tick landing mid-start
    /// never starts it twice, and a failed run waits for its next slot.
    private func begin(_ routine: Routine, at now: Date) -> Routine {
        startingIDs.insert(routine.id)
        routine.lastRunAt = now
        if routine.triggerKind == .once { routine.isEnabled = false }
        lastRuns[routine.id] = LastRun(startedAt: now)
        return routine
    }

    private func run(_ routine: Routine, in context: ModelContext) async {
        let id = routine.id
        let name = routine.name
        let notifies = routine.notifiesOnFinish
        let startedAt = lastRuns[id]?.startedAt ?? now()
        defer { startingIDs.remove(id) }
        do {
            let task = try await startRun(routine, context)
            let tabID = task.orderedTabs.first?.id
            lastRuns[id] = LastRun(startedAt: startedAt, taskID: task.id, tabID: tabID)
            if notifies, let tabID { watchedTabs[tabID] = name }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.app.error("Routine \(name, privacy: .public) failed to start: \(message, privacy: .public)")
            lastRuns[id] = LastRun(startedAt: startedAt, error: message)
        }
    }

    private func tabStatusChanged(tabID: UUID, status: TaskStatus) {
        guard let name = watchedTabs[tabID] else { return }
        if status == .interrupted || status == .interruptedByRestart { watchedTabs[tabID] = nil }
        guard let body = Self.finishBody(for: status) else { return }
        watchedTabs[tabID] = nil
        guard let taskID = StatusEngine.shared.taskID(forTab: tabID) else { return }
        notifier.notifyIfUnseen(.init(
            taskID: taskID,
            tabID: tabID,
            title: name.isEmpty ? "Routine" : name,
            body: body,
            dedupeKey: Notifier.dedupeKey(.status, tabID: tabID)
        ))
    }

    /// Nil while the run's turn is still going or paused on the user, and for
    /// an interruption, which the user caused.
    nonisolated static func finishBody(for status: TaskStatus) -> String? {
        switch status {
        case .awaitingReply: "Routine finished."
        case .error: "Routine stopped with an error."
        case .notStarted, .interrupted, .interruptedByRestart, .working, .waitingOnSubagents, .done, .planApproval, .questionAsked,
             .permissionNeeded, .needsTerminalInput: nil
        }
    }

    func forget(_ routineID: UUID) {
        lastRuns[routineID] = nil
    }
}
