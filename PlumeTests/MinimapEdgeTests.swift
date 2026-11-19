import Foundation
import Testing
@testable import Plume

/// The rail's edge zones: a one-way sweep toward an end scrolls the map all
/// the way to it by the time the pointer reaches that end's zone, whatever
/// the gap when the pointer entered, and does so steadily, without a jump.
/// From inside a zone, the map reaches the end by the rail's end instead.
@MainActor
struct MinimapEdgeTests {
    private static let gain: CGFloat = 10
    private static let travel: CGFloat = 400
    /// A 300 pt rail from y = 10: the top zone ends at 25, the bottom zone
    /// starts at 295, and the rail ends at 310.
    private static let metrics = MinimapMetrics(height: 320, topMargin: 10, bottomInset: 0, contentHeight: 700)
    private static let topZone: CGFloat = 25
    private static let bottomZone: CGFloat = 295
    private static let railEnd: CGFloat = 310

    private static func position(atY y: CGFloat) -> CGFloat {
        MinimapCatchUp.position(pointerFraction: metrics.pointerFraction(atY: y))
    }

    private struct Sample {
        var y: CGFloat
        var offset: CGFloat
    }

    private static func sweep(
        entryOffset: CGFloat,
        from start: CGFloat,
        to end: CGFloat,
        step: CGFloat = 1,
        deadZoneRadius: CGFloat = 16
    ) -> [Sample] {
        var scroll = MinimapHoverScroll(
            offset: entryOffset,
            travel: travel,
            pointer: position(atY: start),
            gain: gain,
            entryY: start,
            deadZoneRadius: deadZoneRadius,
            liveRangeY: metrics.liveRangeY
        )
        var samples = [Sample(y: start, offset: scroll.offset)]
        var y = start
        let direction: CGFloat = end > start ? 1 : -1
        while (end - y) * direction > 0 {
            y = direction > 0 ? min(y + step, end) : max(y - step, end)
            scroll.move(to: position(atY: y), pointerY: y, travel: travel, gain: gain)
            samples.append(Sample(y: y, offset: scroll.offset))
        }
        return samples
    }

    /// The rate never rises above the larger of the sweep's first moving
    /// step's and the catch-up's fastest, `1 + gain` per unit of position.
    private static func expectSteady(_ samples: [Sample], sourceLocation: SourceLocation = #_sourceLocation) {
        let fastestCatchUp = (1 + gain) * travel / (0.9 * 300)
        var firstRate: CGFloat?
        for (previous, sample) in zip(samples, samples.dropFirst()) {
            let moved = sample.offset - previous.offset
            let direction: CGFloat = sample.y > previous.y ? 1 : -1
            #expect(moved * direction >= 0, "offset ran backward at y \(sample.y)", sourceLocation: sourceLocation)
            guard moved != 0 else { continue }
            let rate = abs(moved / (sample.y - previous.y))
            let limit = max(firstRate ?? rate, fastestCatchUp)
            #expect(rate <= limit + 0.0001, "jump of \(moved) at y \(sample.y)", sourceLocation: sourceLocation)
            if firstRate == nil { firstRate = rate }
        }
    }

    private static func offset(at y: CGFloat, in samples: [Sample], down: Bool) -> CGFloat? {
        samples.first { down ? $0.y >= y : $0.y <= y }?.offset
    }

    @Test func aSweepDownReachesTheBottomByItsZone() {
        let samples = Self.sweep(entryOffset: 0, from: 200, to: Self.railEnd)
        #expect(Self.offset(at: Self.bottomZone, in: samples, down: true) == Self.travel)
        #expect(samples.last?.offset == Self.travel)
    }

    @Test func aSweepUpReachesTheTopByItsZone() {
        let samples = Self.sweep(entryOffset: Self.travel, from: 120, to: 0)
        #expect(Self.offset(at: Self.topZone, in: samples, down: false) == 0)
        #expect(samples.last?.offset == 0)
    }

    nonisolated private static let entryOffsets: [CGFloat] = [0, 50, 200, 380, 399, 400]
    nonisolated private static let steps: [CGFloat] = [0.5, 2, 7]

    @Test(arguments: [CGFloat(30), 100, 200, 260, 280, 285, 290, 294])
    func everyEntryReachesTheBottomByItsZone(entryY: CGFloat) {
        for entryOffset in Self.entryOffsets {
            for step in Self.steps {
                for deadZone: CGFloat in [0, 16] {
                    let samples = Self.sweep(entryOffset: entryOffset, from: entryY, to: Self.railEnd, step: step, deadZoneRadius: deadZone)
                    #expect(
                        Self.offset(at: Self.bottomZone, in: samples, down: true) == Self.travel,
                        "entry \(entryY), offset \(entryOffset), step \(step), dead zone \(deadZone)"
                    )
                    Self.expectSteady(samples)
                }
            }
        }
    }

    @Test(arguments: [CGFloat(280), 210, 120, 60, 40, 35, 30, 26])
    func everyEntryReachesTheTopByItsZone(entryY: CGFloat) {
        for entryOffset in Self.entryOffsets {
            for step in Self.steps {
                for deadZone: CGFloat in [0, 16] {
                    let samples = Self.sweep(entryOffset: entryOffset, from: entryY, to: 0, step: step, deadZoneRadius: deadZone)
                    #expect(
                        Self.offset(at: Self.topZone, in: samples, down: false) == 0,
                        "entry \(entryY), offset \(entryOffset), step \(step), dead zone \(deadZone)"
                    )
                    Self.expectSteady(samples)
                }
            }
        }
    }

    @Test(arguments: [CGFloat(296), 300, 305])
    func anEntryInsideTheZoneReachesTheEndByTheRailsEnd(entryY: CGFloat) {
        for entryOffset in Self.entryOffsets {
            let down = Self.sweep(entryOffset: entryOffset, from: entryY, to: Self.railEnd, step: 0.5)
            #expect(down.last?.offset == Self.travel)
            Self.expectSteady(down)

            let mirroredY = 2 * 10 + 300 - entryY
            let up = Self.sweep(entryOffset: entryOffset, from: mirroredY, to: 10, step: 0.5)
            #expect(up.last?.offset == 0)
            Self.expectSteady(up)
        }
    }

    @Test func theDeadZoneStillHoldsAwayFromANearEdge() {
        let samples = Self.sweep(entryOffset: 100, from: 285, to: 270)
        #expect(Set(samples.map(\.offset)) == [100])
    }

    @Test func theDeadZoneStillHoldsAwayFromTheEdges() {
        let samples = Self.sweep(entryOffset: 100, from: 200, to: 215)
        #expect(Set(samples.map(\.offset)) == [100])
    }

    /// Back out of a zone, from the end and from short of it.
    @Test(arguments: [CGFloat(400), 300, 0])
    func leavingTheBottomZoneDoesNotJump(entryOffset: CGFloat) {
        for deadZone: CGFloat in [0, 16] {
            let samples = Self.sweep(entryOffset: entryOffset, from: 305, to: 0, step: 0.5, deadZoneRadius: deadZone)
            Self.expectSteady(samples)
            #expect(Self.offset(at: Self.topZone, in: samples, down: false) == 0)
        }
    }

    @Test(arguments: [CGFloat(0), 100, 400])
    func leavingTheTopZoneDoesNotJump(entryOffset: CGFloat) {
        for deadZone: CGFloat in [0, 16] {
            let samples = Self.sweep(entryOffset: entryOffset, from: 15, to: Self.railEnd, step: 0.5, deadZoneRadius: deadZone)
            Self.expectSteady(samples)
            #expect(Self.offset(at: Self.bottomZone, in: samples, down: true) == Self.travel)
        }
    }
}
