import Foundation
import SwiftData
import Testing

@testable import Plume

/// The Routines group is found by kind, a due routine starts once even when
/// ticks overlap its start, a failed start still stamps the run, and a `once`
/// routine turns itself off.
@MainActor
struct RoutineSchedulerTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self, Routine.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func scheduler(start: @escaping @MainActor (Routine, ModelContext) async throws -> WorkTask) -> RoutineScheduler {
        let scheduler = RoutineScheduler()
        let context = context
        scheduler.context = { context }
        scheduler.startRun = start
        return scheduler
    }

    private func routine(_ trigger: RoutineTrigger, scheduledFrom: Date) -> Routine {
        let routine = Routine(name: "Triage", prompt: "Look", folderPath: "/tmp", now: scheduledFrom)
        routine.trigger = trigger
        context.insert(routine)
        return routine
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
        #expect(routine.lastRunAt == now)
        gate.continuation.yield()
        while scheduler.isStarting(routine.id) { await Task.yield() }
        #expect(starts == 1)
        #expect(scheduler.lastRuns[routine.id]?.taskID != nil)
        #expect(scheduler.lastRuns[routine.id]?.error == nil)
    }

    @Test func aFailedStartRecordsTheErrorAndTheRun() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let routine = routine(.interval(hours: 1), scheduledFrom: created)
        let scheduler = scheduler { _, _ in throw RoutineRunner.Failure.untrusted("/tmp") }
        let now = created.addingTimeInterval(3600)
        scheduler.tick(now: now)
        while scheduler.isStarting(routine.id) { await Task.yield() }
        #expect(scheduler.lastRuns[routine.id]?.error == RoutineRunner.Failure.untrusted("/tmp").errorDescription)
        #expect(routine.lastRunAt == now)
        #expect(scheduler.tick(now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func aOnceRoutineDisablesItselfWhenItRuns() async {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let at = created.addingTimeInterval(600)
        let routine = routine(.once(at), scheduledFrom: created)
        let scheduler = scheduler { _, context in TaskStore.createTask(in: context, groupID: nil) }
        #expect(scheduler.tick(now: at.addingTimeInterval(-1)).isEmpty)
        #expect(scheduler.tick(now: at) == [routine.id])
        #expect(!routine.isEnabled)
        while scheduler.isStarting(routine.id) { await Task.yield() }
        #expect(scheduler.tick(now: at.addingTimeInterval(86400)).isEmpty)
    }

    @Test func nothingRunsWithoutAWindow() {
        let routine = routine(.interval(hours: 1), scheduledFrom: .distantPast)
        let scheduler = RoutineScheduler()
        scheduler.context = { nil }
        #expect(scheduler.tick(now: .now).isEmpty)
        #expect(routine.lastRunAt == nil)
    }

    @Test func finishNotifiesOnlyWhenTheTurnEnds() {
        #expect(RoutineScheduler.finishBody(for: .awaitingReply) != nil)
        #expect(RoutineScheduler.finishBody(for: .error) != nil)
        #expect(RoutineScheduler.finishBody(for: .working) == nil)
        #expect(RoutineScheduler.finishBody(for: .questionAsked) == nil)
        #expect(RoutineScheduler.finishBody(for: .interrupted) == nil)
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

    @Test func aPlainFolderNeverGetsAWorktree() {
        let plan = inputs(folder: "/notes", repo: nil, newWorktree: true).plan(groupID: nil, branchPrefix: "me/")
        #expect(plan.workspace == .directory(path: "/notes", repoPath: nil))
    }
}
