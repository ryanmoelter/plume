import CoreGraphics
import Foundation

/// Whether someone is likely at the Mac, read straight from CoreGraphics so
/// `plume presence` needs no running app.
nonisolated enum Presence {
    enum State: String, Codable, Sendable {
        case awake, asleep, locked
    }

    struct Display: Codable, Equatable, Sendable {
        var id: UInt32
        var asleep: Bool
    }

    struct Report: Codable, Equatable, Sendable {
        var state: State
        var displays: [Display]
        var locked: Bool
    }

    /// A locked screen wins over sleeping displays, since locking usually
    /// comes first. No online display at all — a closed lid with nothing
    /// attached — counts as asleep.
    static func classify(displays: [Display], locked: Bool) -> State {
        if locked { return .locked }
        if displays.allSatisfy(\.asleep) { return .asleep }
        return .awake
    }

    static func report(displays: [Display], locked: Bool) -> Report {
        Report(state: classify(displays: displays, locked: locked), displays: displays, locked: locked)
    }

    static func current() -> Report {
        report(displays: onlineDisplays(), locked: isScreenLocked())
    }

    static func onlineDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { Display(id: $0, asleep: CGDisplayIsAsleep($0) != 0) }
    }

    /// The key is undocumented but long-standing; it is present only while
    /// the screen is locked. Without a GUI session (over SSH) there is no
    /// dictionary, which reads as unlocked.
    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
