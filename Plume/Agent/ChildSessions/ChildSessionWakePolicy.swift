import Foundation

/// When notes from child sessions reach their parent, for one parent tab.
///
/// - A note that wakes reaches an idle parent at once, as a turn of its own.
///   While the parent works, such notes batch until its turn ends.
/// - A note that does not wake (a turn the user drove in the child) is held,
///   the latest per child, and rides in front of the parent's next turn.
/// - After the user interrupts the parent, nothing wakes it: every note waits
///   for the user's next message.
nonisolated struct ChildSessionWakePolicy: Equatable {
    struct Note: Equatable {
        let childID: UUID
        let text: String
    }

    private(set) var held: [Note] = []
    private(set) var waking: [Note] = []
    private(set) var isInterrupted = false

    var isEmpty: Bool { held.isEmpty && waking.isEmpty }

    /// The notes to deliver now as a turn of their own, or nil.
    mutating func noteArrived(_ note: Note, wakes: Bool, parentIsWorking: Bool) -> [Note]? {
        held.removeAll { $0.childID == note.childID }
        guard wakes else {
            held.append(note)
            return nil
        }
        waking.append(note)
        guard !isInterrupted, !parentIsWorking else { return nil }
        return takeAll()
    }

    /// The notes to deliver now that the parent's turn has ended, or nil.
    /// `parentIsWorking` is true when the parent went straight on to a
    /// queued message, whose end delivers them instead.
    mutating func parentTurnFinished(interrupted: Bool, parentIsWorking: Bool) -> [Note]? {
        if interrupted { isInterrupted = true }
        guard !isInterrupted, !parentIsWorking, !waking.isEmpty else { return nil }
        return takeAll()
    }

    /// Every note, to go in front of the message the user is sending.
    mutating func userWillSend() -> [Note] {
        isInterrupted = false
        return takeAll()
    }

    private mutating func takeAll() -> [Note] {
        defer {
            held = []
            waking = []
        }
        return held + waking
    }
}
