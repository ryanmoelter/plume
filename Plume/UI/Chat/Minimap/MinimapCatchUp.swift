import Foundation

/// Maps the pointer onto the minimap's scroll position without ever jumping,
/// the way a synth knob in pickup mode catches up with its parameter.
///
/// Both values are fractions, 0 at the top and 1 at the bottom. The pointer's
/// absolute position is where a direct mapping would put the scroll. While
/// the two differ, a move that heads the scroll toward that position scrolls
/// faster than the pointer, by `1 + gain × gap`, and a move away scrolls
/// slower by the same factor, so either way the gap closes. Once it has
/// closed they move together.
struct MinimapCatchUp: Equatable {
    private(set) var scroll: CGFloat
    private(set) var pointer: CGFloat
    private(set) var isLocked: Bool
    var gain: CGFloat

    /// Below this gap the two count as caught up. The gap closes in
    /// proportion to itself, so without a threshold it never quite would.
    static let lockThreshold: CGFloat = 0.01

    /// The pointer's place in the rail, as the scroll it asks for. The first
    /// and last twentieth pin to the ends, so reaching either does not demand
    /// the very edge of the window.
    static func absolute(pointerFraction fraction: CGFloat) -> CGFloat {
        let span = liveRange.upperBound - liveRange.lowerBound
        return min(max((fraction - liveRange.lowerBound) / span, 0), 1)
    }

    static let liveRange: ClosedRange<CGFloat> = 0.05...0.95

    /// Starts where the map already is, so whatever is under the pointer
    /// stays under it.
    init(scroll: CGFloat, pointer: CGFloat, gain: CGFloat) {
        self.scroll = Self.clamped(scroll)
        self.pointer = Self.clamped(pointer)
        self.gain = gain
        isLocked = abs(self.pointer - self.scroll) < Self.lockThreshold
    }

    mutating func move(to newPointer: CGFloat) {
        let target = Self.clamped(newPointer)
        let delta = target - pointer
        pointer = target
        guard delta != 0 else { return }
        if isLocked {
            scroll = target
            return
        }
        let gap = target - delta - scroll
        let factor = 1 + gain * abs(gap)
        let headsTowardGap = (delta > 0) == (gap > 0)
        let moved = Self.clamped(scroll + (headsTowardGap ? delta * factor : delta / factor))
        // Crossing the pointer, or meeting it, means caught up.
        if (target - moved) * gap <= 0 || abs(target - moved) < Self.lockThreshold {
            scroll = target
            isLocked = true
        } else {
            scroll = moved
        }
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
