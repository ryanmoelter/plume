import AppKit
import Foundation

/// Maps the pointer onto the minimap's scroll position without ever jumping,
/// the way a synth knob in pickup mode catches up with its parameter.
///
/// Scroll is a fraction, 0 at the top and 1 at the bottom. The pointer is a
/// `position`, which asks for the scroll it equals, clamped to `0...1`:
/// past either end it is in an edge zone. While the two differ, a move that
/// heads the scroll toward the asked-for scroll goes faster than the
/// pointer, by `1 + gain × gap`, and a move away goes slower by the same
/// factor, so either way the gap closes. Once it has closed they move
/// together.
///
/// A move toward an end also scrolls at least fast enough to reach that end
/// when the pointer reaches its edge zone, or, from inside the zone, the
/// rail's end. Inside a zone the pointer asks for that end, so without this
/// a gap still open there would never close.
struct MinimapCatchUp: Equatable {
    private(set) var scroll: CGFloat
    private(set) var pointer: CGFloat
    private(set) var isLocked: Bool
    var gain: CGFloat

    /// Below this gap the two count as caught up. The gap closes in
    /// proportion to itself, so without a threshold it never quite would.
    static let lockThreshold: CGFloat = 0.01

    /// The pointer's place in the rail, from its fraction of the rail. The
    /// first and last twentieth are the edge zones, so reaching either end
    /// does not demand the very edge of the window.
    static func position(pointerFraction fraction: CGFloat) -> CGFloat {
        let span = liveRange.upperBound - liveRange.lowerBound
        return (min(max(fraction, 0), 1) - liveRange.lowerBound) / span
    }

    static let liveRange: ClosedRange<CGFloat> = 0.05...0.95

    static let positions = position(pointerFraction: 0)...position(pointerFraction: 1)

    /// Starts where the map already is, so whatever is under the pointer
    /// stays under it. A gap under `lockThreshold` still starts unlocked,
    /// since locking would snap the scroll onto the pointer on the next move;
    /// only rounding's worth of gap counts as level.
    init(scroll: CGFloat, pointer: CGFloat, gain: CGFloat) {
        self.scroll = Self.clamped(scroll)
        self.pointer = min(max(pointer, Self.positions.lowerBound), Self.positions.upperBound)
        self.gain = gain
        isLocked = abs(Self.clamped(self.pointer) - self.scroll) < 1e-9
    }

    mutating func move(to newPointer: CGFloat) {
        let previous = pointer
        pointer = min(max(newPointer, Self.positions.lowerBound), Self.positions.upperBound)
        guard pointer != previous else { return }
        let target = Self.clamped(pointer)
        if isLocked {
            scroll = target
            return
        }
        let delta = target - Self.clamped(previous)
        let gap = Self.clamped(previous) - scroll
        let factor = 1 + gain * abs(gap)
        let headsTowardGap = (delta > 0) == (gap > 0)
        let caughtUp = Self.clamped(scroll + (headsTowardGap ? delta * factor : delta / factor))
        let moved = Self.reachingTheEnd(caughtUp, from: scroll, pointer: previous, to: pointer)
        // Crossing the pointer, or meeting it, means caught up. Coming
        // within the threshold does too, unless locking would pull the
        // scroll back against the move.
        let isNear = abs(target - moved) < Self.lockThreshold && (target - moved) * (pointer - previous) >= 0
        if (target - moved) * gap <= 0 || isNear {
            scroll = target
            isLocked = true
        } else {
            scroll = moved
        }
    }

    /// `moved`, or further toward the end the pointer heads for if the
    /// scroll would otherwise get there after the pointer reaches its edge
    /// zone. It closes the remaining scroll in proportion to the pointer's
    /// remaining way, so a sweep keeps one steady rate, and arrives exactly
    /// as the pointer does.
    private static func reachingTheEnd(_ moved: CGFloat, from scroll: CGFloat, pointer previous: CGFloat, to current: CGFloat) -> CGFloat {
        if current > previous {
            let (from, to, edge) = previous >= 1
                ? (previous, current, positions.upperBound)
                : (max(previous, 0), clamped(current), 1)
            return max(moved, 1 - (1 - scroll) * (edge - to) / (edge - from))
        } else {
            let (from, to, edge) = previous <= 0
                ? (previous, current, positions.lowerBound)
                : (min(previous, 1), clamped(current), 0)
            return min(moved, scroll * (to - edge) / (from - edge))
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
    /// The pointer's height in the pane when the hover began.
    let entryY: CGFloat
    let deadZoneRadius: CGFloat
    /// The pointer heights where the edge zones begin,
    /// `MinimapCatchUp.liveRange` in the pane's points.
    let liveRangeY: ClosedRange<CGFloat>
    /// Whether the pointer is still within `deadZoneRadius` of `entryY`, where
    /// the map holds still so a pointer settling onto a row doesn't scroll it.
    private(set) var isHolding: Bool
    /// Where the map is scrolled, always within `0...travel`.
    var offset: CGFloat { catchUp.scroll * travel }

    /// Pins the catch-up to the map's current offset. An offset past the end
    /// clamps to it, which is where the map has to draw anyway.
    init(
        offset: CGFloat,
        travel: CGFloat,
        pointer: CGFloat,
        gain: CGFloat,
        entryY: CGFloat = 0,
        deadZoneRadius: CGFloat = 0,
        liveRangeY: ClosedRange<CGFloat> = -.infinity ... .infinity
    ) {
        self.travel = max(0, travel)
        let fraction = self.travel > 0 ? min(max(offset, 0), self.travel) / self.travel : 0
        catchUp = MinimapCatchUp(scroll: fraction, pointer: pointer, gain: gain)
        self.entryY = entryY
        self.deadZoneRadius = deadZoneRadius
        self.liveRangeY = liveRangeY
        isHolding = deadZoneRadius > 0
    }

    /// The move that leaves the dead zone only pins the catch-up to where the
    /// pointer now is; the map starts following from the next one, so it
    /// starts from rest rather than jumping by the distance already covered.
    /// A move toward an edge zone the dead zone overlaps is the exception:
    /// the catch-up takes it at once, since the map has to reach the end by
    /// the time the pointer reaches the zone.
    mutating func move(to pointer: CGFloat, pointerY: CGFloat = 0, travel newTravel: CGFloat, gain: CGFloat) {
        repin(travel: newTravel)
        catchUp.gain = gain
        if isHolding {
            if headsForANearEdgeZone(pointerY) {
                isHolding = false
            } else {
                guard abs(pointerY - entryY) >= deadZoneRadius else { return }
                isHolding = false
                catchUp = MinimapCatchUp(scroll: catchUp.scroll, pointer: pointer, gain: gain)
                return
            }
        }
        catchUp.move(to: pointer)
    }

    private func headsForANearEdgeZone(_ pointerY: CGFloat) -> Bool {
        if pointerY > entryY { return liveRangeY.upperBound - entryY < deadZoneRadius }
        if pointerY < entryY { return entryY - liveRangeY.lowerBound < deadZoneRadius }
        return false
    }

    /// Keeps the offset in points across a change of travel, clamped into
    /// the new travel, with the pointer where it was. A scroll locked to the
    /// pointer stays locked instead: a streaming reply changes the travel
    /// constantly, and each re-pin would otherwise unlock it a little.
    mutating func repin(travel newTravel: CGFloat) {
        guard newTravel != travel else { return }
        let pointer = catchUp.pointer
        let newTravel = max(0, newTravel)
        let fraction: CGFloat
        if catchUp.isLocked && !isHolding {
            fraction = min(max(pointer, 0), 1)
        } else {
            fraction = newTravel > 0 ? min(max(offset, 0), newTravel) / newTravel : 0
        }
        travel = newTravel
        catchUp = MinimapCatchUp(scroll: fraction, pointer: pointer, gain: catchUp.gain)
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
        drawableBottom: CGFloat
    ) -> Bool {
        distanceFromEdge >= edgeClearance && distanceFromEdge <= reach && y <= drawableBottom
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
