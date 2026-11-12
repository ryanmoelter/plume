import Foundation
import Testing
@testable import Plume

/// Notes that wake reach an idle parent at once and batch while it works.
/// Notes that don't wake are held, the latest per child, until the parent's
/// next turn. After the user interrupts the parent, everything waits for the
/// user's next message.
struct ChildSessionWakePolicyTests {
    private let childA = UUID()
    private let childB = UUID()

    private func note(_ child: UUID, _ text: String) -> ChildSessionWakePolicy.Note {
        .init(childID: child, text: text)
    }

    @Test func aWakingNoteReachesAnIdleParentAtOnce() {
        var policy = ChildSessionWakePolicy()
        #expect(policy.noteArrived(note(childA, "a"), wakes: true, parentIsWorking: false) == [note(childA, "a")])
        #expect(policy.isEmpty)
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
}
