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

    /// The notes to deliver now as a turn of their own, or nil.
    mutating func noteArrived(_ note: Note, wakes: Bool, _ activity: Activity) -> [Note]? {
        if note.kind == .turnReport { held.removeAll { $0.isTurnReport(from: note.childID) } }
        guard wakes else {
            held.append(note)
            return nil
        }
        waking.append(note)
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

    private mutating func dueWake(_ activity: Activity) -> [Note]? {
        guard !isInterrupted, !activity.parentIsWorking, !activity.childIsWorking, !waking.isEmpty else { return nil }
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
