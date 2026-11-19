import Foundation

/// When notes from child sessions reach their parent, for one parent tab.
///
/// - A note that wakes reaches the parent once the parent is idle and none of
///   its children is working, as a turn of its own. Until then such notes
///   batch.
/// - A note that does not wake (an interrupted child turn, or a child started
///   with `wake_when_done: false`) is held and rides in front of the parent's
///   next turn. A turn report replaces the same child's held report; a
///   message is never dropped or replaced.
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

    /// What decides whether a batch may wake the parent now.
    struct Activity: Equatable {
        var parentIsWorking = false
        var childIsWorking = false
    }

    /// A child working longer than this stops holding its parent's wakes, so
    /// one that never finishes cannot hold them forever.
    static let workingLimit: TimeInterval = 30 * 60

    /// Whether a child mid-turn since `workingSince` still holds wakes at
    /// `now`. A turn with no start time counts as just begun.
    static func holdsWakes(workingSince: Date?, now: Date) -> Bool {
        guard let workingSince else { return true }
        return now.timeIntervalSince(workingSince) < workingLimit
    }

    private(set) var held: [Note] = []
    private(set) var waking: [Note] = []
    private(set) var isInterrupted = false

    var isEmpty: Bool { held.isEmpty && waking.isEmpty }
    var hasWakingNotes: Bool { !waking.isEmpty }

    /// The notes to deliver now as a turn of their own, or nil. A note that
    /// does not wake can still release a batch: it may be the last working
    /// child's turn ending.
    mutating func noteArrived(_ note: Note, wakes: Bool, _ activity: Activity) -> [Note]? {
        if note.kind == .turnReport {
            held.removeAll { $0.isTurnReport(from: note.childID) }
            waking.removeAll { $0.isTurnReport(from: note.childID) }
        }
        if wakes {
            waking.append(note)
        } else {
            held.append(note)
        }
        return dueWake(activity)
    }

    /// The notes to deliver now that the parent's turn has ended, or nil.
    /// `activity.parentIsWorking` is true when the parent went straight on to
    /// a queued message, whose end delivers them instead.
    mutating func parentTurnFinished(interrupted: Bool, _ activity: Activity) -> [Note]? {
        if interrupted { isInterrupted = true }
        return dueWake(activity)
    }

    /// The notes to deliver now that a child stopped counting as working
    /// without finishing a turn: it closed, or it ran past the limit.
    mutating func childrenChanged(_ activity: Activity) -> [Note]? {
        dueWake(activity)
    }

    /// Notes a wake could not deliver, held for the user's next message.
    /// A turn report already waiting from the same child is newer, so it stays.
    mutating func deliveryFailed(_ notes: [Note]) {
        held = notes.filter(isNotSuperseded) + held
    }

    /// Notes taken for a message of the user's that never reached the
    /// parent go back where they were, so a waking one can still wake it.
    mutating func userMessageWithdrawn(_ taken: Taken, _ activity: Activity) -> [Note]? {
        held = taken.held.filter(isNotSuperseded) + held
        waking = taken.waking.filter(isNotSuperseded) + waking
        return dueWake(activity)
    }

    /// Whether `note` is not a turn report older than one already waiting.
    private func isNotSuperseded(_ note: Note) -> Bool {
        note.kind == .message || !(held + waking).contains { $0.isTurnReport(from: note.childID) }
    }

    /// Whether `note` is waiting for the user's next message rather than
    /// for a turn to end.
    func waitsForUser(_ note: Note) -> Bool {
        held.contains(note) || (isInterrupted && waking.contains(note))
    }

    /// The notes taken in one go, split by whether they were waking.
    struct Taken: Equatable {
        var held: [Note] = []
        var waking: [Note] = []
        var all: [Note] { held + waking }
    }

    /// Every note, to go in front of the message the user is sending.
    mutating func userWillSend() -> Taken {
        isInterrupted = false
        return takeAll()
    }

    private mutating func dueWake(_ activity: Activity) -> [Note]? {
        guard !isInterrupted, !activity.parentIsWorking, !activity.childIsWorking, !waking.isEmpty else { return nil }
        return takeAll().all
    }

    private mutating func takeAll() -> Taken {
        defer {
            held = []
            waking = []
        }
        return Taken(held: held, waking: waking)
    }
}

nonisolated private extension ChildSessionWakePolicy.Note {
    func isTurnReport(from child: UUID) -> Bool {
        kind == .turnReport && childID == child
    }
}
