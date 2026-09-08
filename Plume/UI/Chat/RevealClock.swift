import SwiftUI

/// Keeps one chat's reveals from running over each other.
///
/// A block finishing and the next block starting land on the same stream
/// tick, in two different views. Without this they would type at the same
/// time. The block that finishes says how long it needs; the block that
/// starts waits that long before its own reveal begins.
///
/// A class, and never read from a `body`, so holding it costs no
/// invalidation — the same reason `ScrollFollowState` is one.
@MainActor
final class RevealClock {
    private var busyUntil: Date = .distantPast

    /// Claims the next `duration` seconds for a reveal that is starting now.
    func hold(for duration: TimeInterval, now: Date = .now) {
        busyUntil = now.addingTimeInterval(duration)
    }

    /// How long a reveal of `duration` starting now should wait for the one
    /// in flight.
    ///
    /// Never enough to push the pair past `RevealPacing.maxLag`. Waiting its
    /// turn is a nicety; text reaching the reader inside a second is not, so
    /// a block that would be held too long simply overlaps the one above it.
    func wait(before duration: TimeInterval, now: Date = .now) -> TimeInterval {
        let queued = max(0, busyUntil.timeIntervalSince(now))
        return min(queued, max(0, RevealPacing.maxLag - duration))
    }
}

extension EnvironmentValues {
    /// Nil outside a chat list — a preview, say — where reveals have nothing
    /// to queue behind.
    @Entry var revealClock: RevealClock?
}
