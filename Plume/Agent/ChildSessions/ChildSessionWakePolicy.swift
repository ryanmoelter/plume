import Foundation

/// When notes from child sessions reach their parent, for one parent tab.
///
/// - A note that wakes reaches an idle parent at once, as a turn of its own.
///   While the parent works, such notes batch until its turn ends.
/// - A note that does not wake (a turn the user drove in the child) is held
///   and rides in front of the parent's next turn. A turn report replaces
///   the same child's held report; a message is never dropped or replaced.
/// - After the user interrupts the parent, nothing wakes it: every note waits
///   for the user's next message.
nonisolated struct ChildSessionWakePolicy: Equatable {
    struct Note: Equatable {
        enum Kind: Equatable {
            case turnReport
            /// What a child sent with `send_message`.
            case message
        }

        let childID: UUID
        let text: String
        var kind: Kind = .turnReport
    }

    private(set) var held: [Note] = []
    private(set) var waking: [Note] = []
    private(set) var isInterrupted = false

    var isEmpty: Bool { held.isEmpty && waking.isEmpty }

    /// The notes to deliver now as a turn of their own, or nil.
    mutating func noteArrived(_ note: Note, wakes: Bool, parentIsWorking: Bool) -> [Note]? {
        if note.kind == .turnReport { held.removeAll { $0.isTurnReport(from: note.childID) } }
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

    /// Notes a wake could not deliver, held for the user's next message.
    /// A turn report already held from the same child is newer, so it stays.
    mutating func deliveryFailed(_ notes: [Note]) {
        let newer = Set(held.filter { $0.kind == .turnReport }.map(\.childID))
        held = notes.filter { $0.kind == .message || !newer.contains($0.childID) } + held
    }

    /// Whether `note` is waiting for the user's next message rather than
    /// for a turn to end.
    func waitsForUser(_ note: Note) -> Bool {
        held.contains(note) || (isInterrupted && waking.contains(note))
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

nonisolated private extension ChildSessionWakePolicy.Note {
    func isTurnReport(from child: UUID) -> Bool {
        kind == .turnReport && childID == child
    }
}
