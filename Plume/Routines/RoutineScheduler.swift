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
    @ObservationIgnored var preflight: @MainActor (RoutinePlanInputs) async -> RoutineRunner.Failure? = {
        await RoutineRunner.check($0)
    }
    @ObservationIgnored var startRun: @MainActor (
        RoutinePlanInputs, ModelContext, _ beforeLaunch: @escaping @MainActor (WorkTask) -> Void
    ) async throws -> WorkTask = { try await RoutineRunner.start($0, in: $1, beforeLaunch: $2) }
    @ObservationIgnored var notifier: Notifier = .shared

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var launchTick: Task<Void, Never>?
    /// The last window's store. Every window shares the app's one container,
    /// so routines keep running with every window closed.
    @ObservationIgnored private var lastReadyContext: ModelContext?
    @ObservationIgnored private var watchedTabs: [UUID: FinishWatch] = [:]

    private struct FinishWatch {
        var name: String
        var taskID: UUID
        var hasWorked = false
    }

    nonisolated enum FinishStep: Equatable {
        case keepWatching(hasWorked: Bool)
        case stop
        case notify(String)
    }

    static let tickInterval: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { _ = RoutineScheduler.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = RoutineScheduler.shared.tick() }
        }
        StatusEngine.shared.setTabStatusObserver("RoutineScheduler") { [weak self] _, tabID, status, _ in
            self?.tabStatusChanged(tabID: tabID, status: status)
        }
        launchTick = Task { [weak self] in
            while self?.readyContext() == nil {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.tick()
        }
    }

    /// A window's store, or the last one a window had set up. Nil until the
    /// first window is ready.
    func readyContext() -> ModelContext? {
        if let context = context() { lastReadyContext = context }
        return lastReadyContext
    }

    /// Starts every routine due at `now`, and returns their IDs.
    @discardableResult
    func tick(now override: Date? = nil) -> [UUID] {
        guard let context = readyContext() else { return [] }
        let now = override ?? now()
        let calendar = calendar()
        let routines = (try? context.fetch(FetchDescriptor<Routine>(sortBy: [SortDescriptor(\.orderIndex)]))) ?? []
        let due = routines.filter { !startingIDs.contains($0.id) && $0.isDue(now: now, calendar: calendar) }
        for routine in due {
            startingIDs.insert(routine.id)
            Task { await run(routine, at: now, isScheduled: true, in: context) }
        }
        return due.map(\.id)
    }

    /// Runs `routine` now, whether or not it's due. False when it is already
    /// starting or no window is ready.
    @discardableResult
    func runNow(_ routine: Routine) -> Bool {
        guard let context = readyContext(), !startingIDs.contains(routine.id) else { return false }
        startingIDs.insert(routine.id)
        let now = now()
        Task { await run(routine, at: now, isScheduled: false, in: context) }
        return true
    }

    /// Awaits the run, for a caller that reports its outcome.
    func runNowAndWait(_ routine: Routine) async -> LastRun? {
        guard let context = readyContext(), !startingIDs.contains(routine.id) else { return nil }
        startingIDs.insert(routine.id)
        let id = routine.id
        await run(routine, at: now(), isScheduled: false, in: context)
        return lastRuns[id]
    }

    func isStarting(_ id: UUID) -> Bool { startingIDs.contains(id) }

    func isWatching(tabID: UUID) -> Bool { watchedTabs[tabID] != nil }

    /// The caller has already put `routine` in `startingIDs`, so a tick
    /// landing mid-start never starts it twice. A failed preflight leaves
    /// the schedule untouched, so the next tick retries it.
    private func run(_ routine: Routine, at now: Date, isScheduled: Bool, in context: ModelContext) async {
        let id = routine.id
        defer { startingIDs.remove(id) }
        let inputs = RoutinePlanInputs(routine)
        if let failure = await preflight(inputs) {
            record(failure, startedAt: now, for: id, name: inputs.name)
            return
        }
        guard !routine.isDeleted, routine.modelContext != nil else { return }
        begin(routine, at: now, isScheduled: isScheduled, in: context)
        let notifies = routine.notifiesOnFinish
        var watchedTabID: UUID?
        do {
            let task = try await startRun(inputs, context) { [weak self] task in
                guard notifies, let tabID = task.orderedTabs.first?.id else { return }
                watchedTabID = tabID
                self?.watchedTabs[tabID] = FinishWatch(name: inputs.name, taskID: task.id)
            }
            lastRuns[id] = LastRun(startedAt: now, taskID: task.id, tabID: task.orderedTabs.first?.id)
        } catch {
            if let watchedTabID { watchedTabs[watchedTabID] = nil }
            record(error, startedAt: now, for: id, name: inputs.name)
        }
    }

    /// Stamps the run and saves before anything awaits, so a quit or crash
    /// mid-start can't run it twice. Run Now leaves a `once` routine's
    /// scheduled time alone.
    private func begin(_ routine: Routine, at now: Date, isScheduled: Bool, in context: ModelContext) {
        if isScheduled || routine.triggerKind != .once { routine.lastRunAt = now }
        if isScheduled, routine.triggerKind == .once { routine.isEnabled = false }
        lastRuns[routine.id] = LastRun(startedAt: now)
        do {
            try context.save()
        } catch {
            Log.app.error("Could not save routine \(routine.name, privacy: .public) before its run: \(error, privacy: .public)")
        }
    }

    private func record(_ error: Error, startedAt: Date, for id: UUID, name: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if lastRuns[id]?.error != message {
            Log.app.error("Routine \(name, privacy: .public) failed to start: \(message, privacy: .public)")
        }
        lastRuns[id] = LastRun(startedAt: startedAt, error: message)
    }

    private func tabStatusChanged(tabID: UUID, status: TaskStatus) {
        guard var watch = watchedTabs[tabID] else { return }
        switch Self.finishStep(for: status, hasWorked: watch.hasWorked) {
        case .keepWatching(let hasWorked):
            watch.hasWorked = hasWorked
            watchedTabs[tabID] = watch
        case .stop:
            watchedTabs[tabID] = nil
        case .notify(let body):
            watchedTabs[tabID] = nil
            notifier.notifyIfUnseen(.init(
                taskID: watch.taskID,
                tabID: tabID,
                title: watch.name.isEmpty ? "Routine" : watch.name,
                body: body,
                dedupeKey: Notifier.dedupeKey(.status, tabID: tabID)
            ))
        }
    }

    /// A run finishes at the first `awaitingReply` after it has worked; the
    /// idle state a tab reports before its prompt lands is not a finish. An
    /// interruption stops the watch silently, since the user caused it.
    nonisolated static func finishStep(for status: TaskStatus, hasWorked: Bool) -> FinishStep {
        switch status {
        case .error: .notify("Routine stopped with an error.")
        case .awaitingReply: hasWorked ? .notify("Routine finished.") : .keepWatching(hasWorked: false)
        case .interrupted, .interruptedByRestart: .stop
        case .notStarted, .done: .keepWatching(hasWorked: hasWorked)
        case .working, .waitingOnSubagents, .planApproval, .questionAsked, .permissionNeeded, .needsTerminalInput:
            .keepWatching(hasWorked: true)
        }
    }

    func forget(_ routineID: UUID) {
        lastRuns[routineID] = nil
    }
}
