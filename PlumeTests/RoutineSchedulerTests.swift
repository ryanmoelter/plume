import Foundation
import SwiftData
import Testing

@testable import Plume

/// The Routines group is found by kind, a due routine starts once even when
/// ticks overlap its start, a failed preflight leaves the schedule alone, a
/// failed start still stamps the run, and only a scheduled `once` run turns
/// the routine off.
@MainActor
struct RoutineSchedulerTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self, Routine.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func scheduler(
        preflight: RoutineRunner.Failure? = nil,
        start: @escaping @MainActor (RoutinePlanInputs, ModelContext) async throws -> WorkTask = { _, context in
            TaskStore.createTask(in: context, groupID: nil)
        }
    ) -> RoutineScheduler {
        let scheduler = RoutineScheduler()
        let context = context
        scheduler.context = { context }
        scheduler.preflight = { _ in preflight }
        scheduler.startRun = { inputs, context, _ in try await start(inputs, context) }
        return scheduler
    }

    private func routine(_ trigger: RoutineTrigger, scheduledFrom: Date) -> Routine {
        let routine = Routine(name: "Triage", prompt: "Look", folderPath: "/tmp", now: scheduledFrom)
        routine.trigger = trigger
        context.insert(routine)
        return routine
    }

    private func settle(_ scheduler: RoutineScheduler, _ routine: Routine) async {
        while scheduler.isStarting(routine.id) { await Task.yield() }
    }

    @Test func routinesGroupIsCreatedOnceAndFoundByKind() {
        _ = TaskStore.createGroup(in: context, name: "Routines", existing: [])
        #expect(RoutineGroup.find(in: context) == nil)
        let group = RoutineGroup.findOrCreate(in: context)
        #expect(group.kind == .routines)
        group.name = "Scheduled"
        #expect(RoutineGroup.findOrCreate(in: context).id == group.id)
        let groups = (try? context.fetch(FetchDescriptor<TaskGroup>())) ?? []
        #expect(groups.count == 2)
    }

    @Test func aDueRoutineStartsOnceWhileItsStartIsInFlight() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let routine = routine(.interval(hours: 1), scheduledFrom: created)
        var starts = 0
        let gate = AsyncStream<Void>.makeStream()
        let scheduler = scheduler { _, context in
            starts += 1
            for await _ in gate.stream { break }
            return TaskStore.createTask(in: context, groupID: nil)
        }
        let now = created.addingTimeInterval(3600)
        #expect(scheduler.tick(now: now) == [routine.id])
        #expect(scheduler.tick(now: now.addingTimeInterval(7200)).isEmpty)
        while starts == 0 { await Task.yield() }
        #expect(routine.lastRunAt == now)
        gate.continuation.yield()
        await settle(scheduler, routine)
        #expect(starts == 1)
        #expect(scheduler.lastRuns[routine.id]?.taskID != nil)
        #expect(scheduler.lastRuns[routine.id]?.error == nil)
    }

    @Test func aFailedPreflightKeepsTheSlotAndRetriesNextTick() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let routine = routine(.interval(hours: 1), scheduledFrom: created)
        var starts = 0
        let scheduler = scheduler(preflight: .folderMissing("/tmp")) { _, context in
            starts += 1
            return TaskStore.createTask(in: context, groupID: nil)
        }
        let now = created.addingTimeInterval(3600)
        scheduler.tick(now: now)
        await settle(scheduler, routine)
        #expect(scheduler.lastRuns[routine.id]?.error == RoutineRunner.Failure.folderMissing("/tmp").errorDescription)
        #expect(routine.lastRunAt == nil)
        #expect(starts == 0)
        scheduler.preflight = { _ in nil }
        #expect(scheduler.tick(now: now.addingTimeInterval(30)) == [routine.id])
        await settle(scheduler, routine)
        #expect(starts == 1)
        #expect(scheduler.lastRuns[routine.id]?.error == nil)
    }

    @Test func aFailedPreflightLeavesAOnceRoutineOn() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let at = created.addingTimeInterval(600)
        let routine = routine(.once(at), scheduledFrom: created)
        let scheduler = scheduler(preflight: .cliMissing(.claudeCode))
        scheduler.tick(now: at)
        await settle(scheduler, routine)
        #expect(routine.isEnabled)
        #expect(routine.isDue(now: at.addingTimeInterval(30)))
    }

    @Test func aFailedStartRecordsTheErrorAndTheRun() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let routine = routine(.interval(hours: 1), scheduledFrom: created)
        let scheduler = scheduler { _, _ in throw RoutineRunner.Failure.untrusted("/tmp") }
        let now = created.addingTimeInterval(3600)
        scheduler.tick(now: now)
        await settle(scheduler, routine)
        #expect(scheduler.lastRuns[routine.id]?.error == RoutineRunner.Failure.untrusted("/tmp").errorDescription)
        #expect(routine.lastRunAt == now)
        #expect(scheduler.tick(now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func aOnceRoutineDisablesItselfWhenItRuns() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let at = created.addingTimeInterval(600)
        let routine = routine(.once(at), scheduledFrom: created)
        let scheduler = scheduler()
        #expect(scheduler.tick(now: at.addingTimeInterval(-1)).isEmpty)
        #expect(scheduler.tick(now: at) == [routine.id])
        await settle(scheduler, routine)
        #expect(!routine.isEnabled)
        #expect(scheduler.tick(now: at.addingTimeInterval(86400)).isEmpty)
    }

    @Test func runNowKeepsAOnceRoutineScheduled() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let at = created.addingTimeInterval(86400)
        let routine = routine(.once(at), scheduledFrom: created)
        let scheduler = scheduler()
        scheduler.now = { created.addingTimeInterval(60) }
        let run = await scheduler.runNowAndWait(routine)
        #expect(run?.taskID != nil)
        #expect(routine.isEnabled)
        #expect(routine.nextFireDate() == at)
        #expect(scheduler.tick(now: at) == [routine.id])
    }

    @Test func nothingRunsBeforeAWindowIsReady() {
        let routine = routine(.interval(hours: 1), scheduledFrom: .distantPast)
        let scheduler = RoutineScheduler()
        scheduler.context = { nil }
        #expect(scheduler.tick(now: .now).isEmpty)
        #expect(routine.lastRunAt == nil)
    }

    @Test func routinesKeepRunningAfterTheLastWindowCloses() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let routine = routine(.interval(hours: 1), scheduledFrom: created)
        let scheduler = scheduler()
        #expect(scheduler.tick(now: created).isEmpty)
        scheduler.context = { nil }
        #expect(scheduler.tick(now: created.addingTimeInterval(3600)) == [routine.id])
        await settle(scheduler, routine)
    }

    @Test func theFinishWatchIsInPlaceBeforeTheAgentLaunches() async {
        let routine = routine(.interval(hours: 1), scheduledFrom: .distantPast)
        routine.notifiesOnFinish = true
        let scheduler = scheduler()
        var watchedBeforeLaunch = false
        scheduler.startRun = { _, context, beforeLaunch in
            let task = TaskStore.createTask(in: context, groupID: nil)
            beforeLaunch(task)
            watchedBeforeLaunch = scheduler.isWatching(tabID: task.orderedTabs[0].id)
            return task
        }
        _ = await scheduler.runNowAndWait(routine)
        #expect(watchedBeforeLaunch)
    }

    @Test func finishWaitsForTheTabToWork() {
        #expect(RoutineScheduler.finishStep(for: .awaitingReply, hasWorked: false) == .keepWatching(hasWorked: false))
        #expect(RoutineScheduler.finishStep(for: .notStarted, hasWorked: false) == .keepWatching(hasWorked: false))
        #expect(RoutineScheduler.finishStep(for: .working, hasWorked: false) == .keepWatching(hasWorked: true))
        #expect(RoutineScheduler.finishStep(for: .questionAsked, hasWorked: true) == .keepWatching(hasWorked: true))
        #expect(RoutineScheduler.finishStep(for: .awaitingReply, hasWorked: true) == .notify("Routine finished."))
        #expect(RoutineScheduler.finishStep(for: .interrupted, hasWorked: true) == .stop)
    }

    @Test func anEarlyErrorStillNotifies() {
        #expect(RoutineScheduler.finishStep(for: .error, hasWorked: false) == .notify("Routine stopped with an error."))
    }
}

/// What a run checks before creating a task, and the plan it starts.
struct RoutineRunnerTests {
    private func preflight(
        prompt: String = "Go", provider: AgentProviderKind = .claudeCode, checksTrust: Bool = true,
        exists: Bool = true, trusted: Bool = true, installed: Bool = true
    ) -> RoutineRunner.Failure? {
        RoutineRunner.preflight(
            prompt: prompt, folder: "/repo", provider: provider, checksTrust: checksTrust,
            folderExists: { _ in exists }, isTrusted: { _ in trusted }, isInstalled: { _ in installed }
        )
    }

    @Test func preflightNamesWhatStopsARun() {
        #expect(preflight() == nil)
        #expect(preflight(prompt: "  ") == .emptyPrompt)
        #expect(preflight(exists: false) == .folderMissing("/repo"))
        #expect(preflight(installed: false) == .cliMissing(.claudeCode))
        #expect(preflight(trusted: false) == .untrusted("/repo"))
        #expect(preflight(checksTrust: false, trusted: false) == nil)
        #expect(preflight(provider: .codex, trusted: false) == nil)
    }

    private func inputs(folder: String, repo: String?, newWorktree: Bool) -> RoutinePlanInputs {
        RoutinePlanInputs(
            name: "Nightly triage", prompt: "Triage", folderPath: folder, repoPath: repo,
            runsInNewWorktree: newWorktree, choices: TabLaunchChoices(providerID: "claude-code", transportRaw: "terminal")
        )
    }

    @Test func aFolderRunStartsInTheFolderOnHeadless() {
        let group = UUID()
        let plan = inputs(folder: "/repo/app", repo: "/repo", newWorktree: false).plan(groupID: group, branchPrefix: "me/")
        #expect(plan.workspace == .directory(path: "/repo/app", repoPath: "/repo"))
        #expect(plan.groupID == group)
        #expect(plan.message == "Triage")
        #expect(plan.choices?.transportRaw == AgentTransport.headless.rawValue)
    }

    @Test func aWorktreeRunBranchesFromTheNameAndKeepsTheSubfolder() {
        let plan = inputs(folder: "/repo/app", repo: "/repo", newWorktree: true)
            .plan(groupID: nil, branchPrefix: "me/", branchSuffix: "abcd")
        #expect(plan.workspace == .newWorktree(repository: "/repo", branch: "me/nightly-triage-abcd"))
        #expect(plan.subfolder == "app")
    }

    @Test func aFolderInALinkedWorktreeKeepsItsSubfolderInThatCheckout() {
        let plan = inputs(folder: "/repo/.plume/worktrees/topic/app", repo: "/repo", newWorktree: true)
            .plan(groupID: nil, branchPrefix: "me/", checkoutRoot: "/repo/.plume/worktrees/topic", branchSuffix: "abcd")
        #expect(plan.subfolder == "app")
        let external = inputs(folder: "/elsewhere/topic/app", repo: "/repo", newWorktree: true)
            .plan(groupID: nil, branchPrefix: "me/", checkoutRoot: "/elsewhere/topic", branchSuffix: "abcd")
        #expect(external.subfolder == "app")
        let root = inputs(folder: "/repo/.plume/worktrees/topic", repo: "/repo", newWorktree: true)
            .plan(groupID: nil, branchPrefix: "me/", checkoutRoot: "/repo/.plume/worktrees/topic", branchSuffix: "abcd")
        #expect(root.subfolder == nil)
    }

    @Test func aPlainFolderNeverGetsAWorktree() {
        let plan = inputs(folder: "/notes", repo: nil, newWorktree: true).plan(groupID: nil, branchPrefix: "me/")
        #expect(plan.workspace == .directory(path: "/notes", repoPath: nil))
    }
}
