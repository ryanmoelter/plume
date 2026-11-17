import AppKit
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

/// The catch-up in the map's own points. The catch-up works in fractions of
/// `travel`, so a change in travel mid-hover — a reply streaming in, a new
/// prompt — would turn the same fraction into a different offset and jump
/// the map. Re-pinning on a change keeps the offset where it is instead.
struct MinimapHoverScroll: Equatable {
    private(set) var catchUp: MinimapCatchUp
    private(set) var travel: CGFloat
    /// Where the map is scrolled, always within `0...travel`.
    var offset: CGFloat { catchUp.scroll * travel }

    /// Pins the catch-up to the map's current offset. An offset past the end
    /// clamps to it, which is where the map has to draw anyway.
    init(offset: CGFloat, travel: CGFloat, pointer: CGFloat, gain: CGFloat) {
        self.travel = max(0, travel)
        let fraction = self.travel > 0 ? min(max(offset, 0), self.travel) / self.travel : 0
        catchUp = MinimapCatchUp(scroll: fraction, pointer: pointer, gain: gain)
    }

    mutating func move(to pointer: CGFloat, travel newTravel: CGFloat, gain: CGFloat) {
        repin(travel: newTravel)
        catchUp.gain = gain
        catchUp.move(to: pointer)
    }

    /// Keeps the offset in points across a change of travel, clamped into
    /// the new travel, with the pointer where it was. A scroll locked to the
    /// pointer stays locked instead: a streaming reply changes the travel
    /// constantly, and each re-pin would otherwise unlock it a little.
    mutating func repin(travel newTravel: CGFloat) {
        guard newTravel != travel else { return }
        let pointer = catchUp.pointer
        if catchUp.isLocked {
            travel = max(0, newTravel)
            catchUp = MinimapCatchUp(scroll: pointer, pointer: pointer, gain: catchUp.gain)
        } else {
            self = MinimapHoverScroll(offset: offset, travel: newTravel, pointer: pointer, gain: catchUp.gain)
        }
    }
}

/// Where a click on the hovered rail selects a row rather than reaching the
/// chat under it: out to the hovered bar's drawn end but clear of the pane's
/// edge itself, below the band beside the info pane, and above the composer.
enum MinimapClickZone {
    /// Kept free at the pane's edge, where a split divider's grip, the
    /// sidebar divider or the window's resize edge overhangs the pane. The
    /// split divider's grip is 9 pt wide and centered on the boundary.
    static let edgeClearance: CGFloat = 5

    /// How far past a bar's drawn end a click still lands on it.
    static let slop: CGFloat = 4

    /// How far from the pane's edge a click reaches the hovered bar, which
    /// draws `inset` from the edge and `barWidth` long once magnified.
    static func reach(inset: CGFloat, barWidth: CGFloat) -> CGFloat {
        inset + barWidth + slop
    }

    static func accepts(
        distanceFromEdge: CGFloat,
        y: CGFloat,
        reach: CGFloat,
        exclusionHeight: CGFloat,
        drawableBottom: CGFloat
    ) -> Bool {
        distanceFromEdge >= edgeClearance && distanceFromEdge <= reach
            && y >= exclusionHeight && y <= drawableBottom
    }

    /// Whether the view a click lands on is the chat's own content, which a
    /// click on the rail may take. Anything else under the pointer — a
    /// divider, a scroller, the window frame — owns the click.
    static func isChatContent(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is NSScroller { return false }
            if candidate is ChatListDocumentView { return true }
            if let scroll = candidate as? NSScrollView { return scroll.documentView is ChatListDocumentView }
            current = candidate.superview
        }
        return false
    }
}
