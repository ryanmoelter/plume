import Foundation
import SwiftData
import Testing

@testable import Plume

/// A spent `once` routine stays editable without a new date, a new future
/// date turns it back on, and the Codex collaboration mode survives a save.
@MainActor
struct RoutineDraftTests {
    private let context: ModelContext
    private let now = Date(timeIntervalSince1970: 2_000_000)

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([Routine.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func spentOnceRoutine() -> Routine {
        let routine = Routine(name: "Once", prompt: "Go", folderPath: "/tmp", now: now.addingTimeInterval(-7200))
        routine.trigger = .once(now.addingTimeInterval(-3600))
        routine.isEnabled = false
        context.insert(routine)
        return routine
    }

    @Test func aSpentOnceRoutineSavesWithItsDateUnchanged() {
        let routine = spentOnceRoutine()
        var draft = RoutineDraft(routine)
        draft.prompt = "Go again"
        #expect(draft.problem(now: now) == nil)
        draft.apply(to: routine, now: now)
        #expect(routine.prompt == "Go again")
        #expect(!routine.isEnabled)
    }

    @Test func aNewPastOnceDateIsRefused() {
        var draft = RoutineDraft(spentOnceRoutine())
        draft.onceDate = now.addingTimeInterval(-60)
        #expect(draft.problem(now: now) != nil)
    }

    @Test func aNewFutureOnceDateTurnsTheRoutineBackOn() {
        let routine = spentOnceRoutine()
        var draft = RoutineDraft(routine)
        draft.onceDate = now.addingTimeInterval(600)
        #expect(draft.problem(now: now) == nil)
        draft.apply(to: routine, now: now)
        #expect(routine.isEnabled)
        #expect(routine.isDue(now: now.addingTimeInterval(600)))
    }

    @Test func codexCollaborationModeRoundTrips() {
        let routine = Routine()
        var choices = routine.launchChoices
        choices.codexCollaborationModeRaw = "plan"
        routine.launchChoices = choices
        #expect(routine.launchChoices.codexCollaborationModeRaw == "plan")
    }
}
