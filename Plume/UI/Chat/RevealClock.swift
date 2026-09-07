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

    /// How long a reveal starting now should wait for the one in flight.
    ///
    /// Capped, so a reveal that was interrupted and never finished cannot
    /// stall the block behind it for longer than one full reveal.
    func wait(now: Date = .now) -> TimeInterval {
        min(RevealPacing.maxDuration, max(0, busyUntil.timeIntervalSince(now)))
    }
}

extension EnvironmentValues {
    /// Nil outside a chat list — a preview, say — where reveals have nothing
    /// to queue behind.
    @Entry var revealClock: RevealClock?
}
