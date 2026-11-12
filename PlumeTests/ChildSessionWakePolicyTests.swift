import Foundation
import Testing
@testable import Plume

/// Notes that wake reach an idle parent at once and batch while it works.
/// Turn reports that don't wake are held, the latest per child, until the
/// parent's next turn; a message is never dropped or replaced. After the user interrupts the parent, everything waits for the
/// user's next message.
struct ChildSessionWakePolicyTests {
    private let childA = UUID()
    private let childB = UUID()

    private func note(_ child: UUID, _ text: String) -> ChildSessionWakePolicy.Note {
        .init(childID: child, text: text)
    }

    private func message(_ child: UUID, _ text: String) -> ChildSessionWakePolicy.Note {
        .init(childID: child, text: text, kind: .message)
    }

    @Test func aWakingNoteReachesAnIdleParentAtOnce() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, parentIsWorking: false) == [note(childA, "a")])
        #expect(policy.isEmpty)
    }

    @Test func notesAFailedWakeCouldNotDeliverWaitForTheUser() {
        var policy = ChildSessionWakePolicy()
        let due = policy.noteArrived(note(childA, "a"), wakes: true, parentIsWorking: false) ?? []
        _ = policy.noteArrived(note(childB, "b2"), wakes: false, parentIsWorking: false)

        policy.deliveryFailed(due + [note(childB, "b1")])

        #expect(policy.parentTurnFinished(interrupted: false, parentIsWorking: false) == nil)
        #expect(policy.userWillSend() == [note(childA, "a"), note(childB, "b2")])
    }

    @Test func wakingNotesBatchWhileTheParentWorks() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, parentIsWorking: true) == nil)
        #expect(policy.noteArrived(note(childB, "b"), wakes: true, parentIsWorking: true) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, parentIsWorking: true) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, parentIsWorking: false) == [note(childA, "a"), note(childB, "b")])
    }

    @Test func aHeldNoteKeepsOnlyTheLatestPerChildAndRidesTheNextTurn() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "old"), wakes: false, parentIsWorking: false) == nil)
        #expect(policy.noteArrived(note(childA, "new"), wakes: false, parentIsWorking: false) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, parentIsWorking: false) == nil)
        #expect(policy.userWillSend() == [note(childA, "new")])
        #expect(policy.isEmpty)
    }

    @Test func aWakeCarriesHeldNotesInFront() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "held"), wakes: false, parentIsWorking: false)
        #expect(policy.noteArrived(note(childB, "wake"), wakes: true, parentIsWorking: false) == [note(childA, "held"), note(childB, "wake")])
    }

    @Test func aWakingNoteReplacesThatChildsHeldOne() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "held"), wakes: false, parentIsWorking: false)
        #expect(policy.noteArrived(note(childA, "wake"), wakes: true, parentIsWorking: false) == [note(childA, "wake")])
    }

    @Test func afterAnInterruptNotesWaitForTheUser() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.parentTurnFinished(interrupted: true, parentIsWorking: false) == nil)
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, parentIsWorking: false) == nil)
        #expect(policy.parentTurnFinished(interrupted: false, parentIsWorking: false) == nil)
        #expect(policy.userWillSend() == [note(childA, "a")])
        #expect(policy.noteArrived(note(childB, "b"), wakes: true, parentIsWorking: false) == [note(childB, "b")])
    }

    @Test func thereIsNoCapOnWakes() {
        var policy = ChildSessionWakePolicy()
        for index in 0..<50 {
            #expect(policy.noteArrived(note(childA, "\(index)"), wakes: true, parentIsWorking: false)?.count == 1)
        }
    }

    @Test func aChildsMessagesAreNeverReplaced() {
        var policy = ChildSessionWakePolicy()
        _ = policy.parentTurnFinished(interrupted: true, parentIsWorking: false)
        _ = policy.noteArrived(message(childA, "first"), wakes: true, parentIsWorking: false)
        _ = policy.noteArrived(note(childA, "report"), wakes: false, parentIsWorking: false)
        _ = policy.noteArrived(message(childA, "second"), wakes: true, parentIsWorking: false)
        _ = policy.noteArrived(note(childA, "newer report"), wakes: false, parentIsWorking: false)

        #expect(policy.userWillSend() == [
            note(childA, "newer report"), message(childA, "first"), message(childA, "second"),
        ])
    }

    @Test func aFailedWakeKeepsEveryMessageButOnlyTheNewerReport() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(note(childA, "newer report"), wakes: false, parentIsWorking: false)

        policy.deliveryFailed([message(childA, "one"), note(childA, "old report"), message(childA, "two")])

        #expect(policy.userWillSend() == [message(childA, "one"), message(childA, "two"), note(childA, "newer report")])
    }

    @Test func aNoteWaitsForTheUserOnlyWhenHeldOrInterrupted() {
        var policy = ChildSessionWakePolicy()
        _ = policy.noteArrived(message(childA, "batched"), wakes: true, parentIsWorking: true)
        #expect(!policy.waitsForUser(message(childA, "batched")))

        _ = policy.parentTurnFinished(interrupted: true, parentIsWorking: false)
        #expect(policy.waitsForUser(message(childA, "batched")))
    }
}
