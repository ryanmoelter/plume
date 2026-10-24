import Foundation
import GhosttyTerminal

/// Ticks the ghostty app while no terminal view is in a window.
///
/// The wrapper empties ghostty's app mailbox — bells, titles, child exits —
/// only on a wakeup that some window-attached surface accepts, and drops the
/// wakeup otherwise. A task of only chat tabs mounts no terminal, so while it
/// is selected every other task's bell would wait until its own task is shown
/// again, and then count as already seen.
@MainActor
final class DetachedSurfaceTicker {
    private static let interval: Duration = .milliseconds(250)

    private var loop: Task<Void, Never>?

    /// With any view attached, the wrapper's own wakeups already tick.
    nonisolated static func needsTick(attachment: some Sequence<Bool>) -> Bool {
        var sawSession = false
        for attached in attachment {
            if attached { return false }
            sawSession = true
        }
        return sawSession
    }

    func start(needsTick: @escaping @MainActor () -> Bool) {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(100))
                if needsTick() { GhosttyRuntime.shared.controller?.tick() }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
