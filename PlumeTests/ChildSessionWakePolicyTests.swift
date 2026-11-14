import Foundation
import Testing
@testable import Plume

/// Notes that wake reach the parent once it is idle and none of its children
/// is working, and batch until then. Reports that don't wake are held, the
/// latest per child, until the parent's next turn; a message is never dropped
/// or replaced. After the user interrupts the parent, everything waits for
/// the user's next message.
struct ChildSessionWakePolicyTests {
    private let childA = UUID()
    private let childB = UUID()
    private let idle = ChildSessionWakePolicy.Activity()
    private let parentWorking = ChildSessionWakePolicy.Activity(parentIsWorking: true)
    private let childWorking = ChildSessionWakePolicy.Activity(childIsWorking: true)

    private func note(_ child: UUID, _ text: String) -> ChildSessionWakePolicy.Note {
        .init(childID: child, text: text)
    }

    private func message(_ child: UUID, _ text: String) -> ChildSessionWakePolicy.Note {
        .init(childID: child, text: text, kind: .message)
    }

    @Test func aWakingNoteReachesAnIdleParentAtOnce() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, idle) == [note(childA, "a")])
        #expect(policy.isEmpty)
    }

    @Test func notesAFailedWakeCouldNotDeliverWaitForTheUser() {
        var policy = ChildSessionWakePolicy()
        let due = policy.noteArrived(note(childA, "a"), wakes: true, idle) ?? []
        _ = policy.noteArrived(note(childB, "b2"), wakes: false, idle)

        policy.deliveryFailed(due + [note(childB, "b1")])

        #expect(policy.parentTurnFinished(interrupted: false, idle) == nil)
        #expect(policy.userWillSend() == [note(childA, "a"), note(childB, "b2")])
    }

    @Test func wakingNotesBatchWhileTheParentWorks() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, parentWorking) == nil)
        #expect(policy.noteArrived(note(childB, "b"), wakes: true, parentWorking) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, parentWorking) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, idle) == [note(childA, "a"), note(childB, "b")])
    }

    @Test func wakingNotesBatchWhileAnotherChildWorks() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, childWorking) == nil)
        #expect(policy.noteArrived(message(childB, "mid-turn"), wakes: true, childWorking) == nil)
        #expect(policy.noteArrived(note(childB, "b"), wakes: true, idle)
            == [note(childA, "a"), message(childB, "mid-turn"), note(childB, "b")])
    }

    @Test func theParentsTurnEndWaitsForWorkingChildren() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "a"), wakes: true, parentWorking)
        #expect(policy.parentTurnFinished(interrupted: false, childWorking) == nil)
        #expect(policy.childrenChanged(idle) == [note(childA, "a")])
    }

    @Test func aChildThatStopsCountingReleasesTheBatch() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "a"), wakes: true, childWorking)
        #expect(policy.childrenChanged(childWorking) == nil)
        #expect(policy.hasWakingNotes)
        #expect(policy.childrenChanged(idle) == [note(childA, "a")])
        #expect(policy.childrenChanged(idle) == nil)
    }

    @Test func onlyHeldNotesNeverWake() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "held"), wakes: false, idle)
        #expect(policy.childrenChanged(idle) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, idle) == nil)
    }

    /// 30 minutes, as `workingLimit` sets.
    @Test func aChildWorkingPastTheLimitStopsHoldingWakes() {
        let now = Date()
        #expect(ChildSessionWakePolicy.holdsWakes(workingSince: now.addingTimeInterval(-29 * 60), now: now))
        #expect(!ChildSessionWakePolicy.holdsWakes(workingSince: now.addingTimeInterval(-30 * 60), now: now))
        #expect(ChildSessionWakePolicy.holdsWakes(workingSince: nil, now: now))
    }

    @Test func aHeldNoteKeepsOnlyTheLatestPerChildAndRidesTheNextTurn() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "old"), wakes: false, idle) == nil)
        #expect(policy.noteArrived(note(childA, "new"), wakes: false, idle) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, idle) == nil)
        #expect(policy.userWillSend() == [note(childA, "new")])
        #expect(policy.isEmpty)
    }

    @Test func aWakeCarriesHeldNotesInFront() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "held"), wakes: false, idle)
        #expect(policy.noteArrived(note(childB, "wake"), wakes: true, idle) == [note(childA, "held"), note(childB, "wake")])
    }

    @Test func aWakingNoteReplacesThatChildsHeldOne() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "held"), wakes: false, idle)
        #expect(policy.noteArrived(note(childA, "wake"), wakes: true, idle) == [note(childA, "wake")])
    }

    @Test func afterAnInterruptNotesWaitForTheUser() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.parentTurnFinished(interrupted: true, idle) == nil)
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, idle) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, idle) == nil)
        #expect(policy.childrenChanged(idle) == nil)
        #expect(policy.userWillSend() == [note(childA, "a")])
        #expect(policy.noteArrived(note(childB, "b"), wakes: true, idle) == [note(childB, "b")])
    }

    @Test func thereIsNoCapOnWakes() {
        var policy = ChildSessionWakePolicy()
        for index in 0..<50 {
            #expect(policy.noteArrived(note(childA, "\(index)"), wakes: true, idle)?.count == 1)
        }
    }

    @Test func aChildsMessagesAreNeverReplaced() {
        var policy = ChildSessionWakePolicy()
        _ = policy.parentTurnFinished(interrupted: true, idle)
        _ = policy.noteArrived(message(childA, "first"), wakes: true, idle)
        _ = policy.noteArrived(note(childA, "report"), wakes: false, idle)
        _ = policy.noteArrived(message(childA, "second"), wakes: true, idle)
        _ = policy.noteArrived(note(childA, "newer report"), wakes: false, idle)

        #expect(policy.userWillSend() == [
            note(childA, "newer report"), message(childA, "first"), message(childA, "second"),
        ])
    }

    @Test func aFailedWakeKeepsEveryMessageButOnlyTheNewerReport() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "newer report"), wakes: false, idle)

        policy.deliveryFailed([message(childA, "one"), note(childA, "old report"), message(childA, "two")])

        #expect(policy.userWillSend() == [message(childA, "one"), message(childA, "two"), note(childA, "newer report")])
    }

    @Test func aNoteWaitsForTheUserOnlyWhenHeldOrInterrupted() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(message(childA, "batched"), wakes: true, parentWorking)
        #expect(!policy.waitsForUser(message(childA, "batched")))

        _ = policy.parentTurnFinished(interrupted: true, idle)
        #expect(policy.waitsForUser(message(childA, "batched")))
    }
}
