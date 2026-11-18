import Foundation
import Testing
@testable import Plume

/// The snapped scroll hovers exactly the rows the continuous scroll would,
/// for any pointer input. Only the drawn offset differs: it holds while the
/// hovered row stays the same and steps to the catch-up's offset when it
/// changes.
@MainActor
struct MinimapSnappedScrollTests {
    private static let rowSpacing: CGFloat = 10
    private static let travel: CGFloat = 400
    private static let live: CGFloat = 300

    /// Rows every `rowSpacing` of content, from row 0 at the top.
    private static func rowAt(pointerY: CGFloat) -> (CGFloat) -> String? {
        { offset in "r\(max(0, Int(((pointerY + offset) / rowSpacing).rounded())))" }
    }

    private struct Frame: Equatable {
        var rowID: String?
        var displayed: CGFloat
        var target: CGFloat
    }

    /// Runs one pointer path through the catch-up, hovering as each mode
    /// does: continuous draws at the target, snapped through `step`.
    private static func run(_ path: [CGFloat], snapped: Bool, deadZoneRadius: CGFloat = 16) -> [Frame] {
        guard let first = path.first else { return [] }
        var scroll = MinimapHoverScroll(
            offset: 120,
            travel: travel,
            pointer: MinimapCatchUp.absolute(pointerFraction: first / live),
            gain: 10,
            entryY: first,
            deadZoneRadius: deadZoneRadius
        )
        var hovered: String?
        var displayed: CGFloat = 120
        var frames: [Frame] = []
        for (index, y) in path.enumerated() {
            if index > 0 {
                scroll.move(to: MinimapCatchUp.absolute(pointerFraction: y / live), pointerY: y, travel: travel, gain: 10)
            }
            let rowAt = rowAt(pointerY: y)
            if snapped {
                let step = MinimapSnappedScroll.step(
                    hoveredRowID: hovered,
                    displayed: displayed,
                    target: scroll.offset,
                    rowAt: rowAt
                )
                hovered = step.rowID
                displayed = step.offset
            } else {
                displayed = scroll.offset
                hovered = rowAt(displayed)
            }
            frames.append(Frame(rowID: hovered, displayed: displayed, target: scroll.offset))
        }
        return frames
    }

    /// A deterministic pointer wander inside the rail, mixing small jitters
    /// with longer sweeps.
    private static func path(seed: UInt64, count: Int = 300) -> [CGFloat] {
        var state = seed
        var y = live / 2
        var path: [CGFloat] = []
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
            let reach: CGFloat = (state >> 20) & 7 == 0 ? 40 : 4
            y = min(max(y + (unit - 0.5) * 2 * reach, 0), live)
            path.append(y)
        }
        return path
    }

    nonisolated private static let seeds: [UInt64] = [1, 7, 42, 1234, 99_991, 31_337]

    @Test(arguments: seeds)
    func bothModesHoverTheSameRows(seed: UInt64) {
        let path = Self.path(seed: seed)
        let continuous = Self.run(path, snapped: false).map(\.rowID)
        let snapped = Self.run(path, snapped: true).map(\.rowID)
        #expect(continuous == snapped)
    }

    @Test(arguments: seeds)
    func theDrawnOffsetMovesOnlyWithTheHoveredRow(seed: UInt64) {
        let frames = Self.run(Self.path(seed: seed), snapped: true)
        for (previous, frame) in zip(frames, frames.dropFirst()) {
            if frame.rowID == previous.rowID {
                #expect(frame.displayed == previous.displayed)
            } else {
                #expect(frame.displayed == frame.target)
            }
        }
    }

    @Test(arguments: seeds)
    func afterAStepTheHoveredRowIsUnderThePointer(seed: UInt64) {
        let path = Self.path(seed: seed)
        let frames = Self.run(path, snapped: true)
        for (index, frame) in frames.enumerated() where index == 0 || frame.rowID != frames[index - 1].rowID {
            #expect(Self.rowAt(pointerY: path[index])(frame.displayed) == frame.rowID)
        }
    }

    @Test func theMapHoldsStillWhileTheRowIsUnchanged() {
        let step = MinimapSnappedScroll.step(hoveredRowID: "r8", displayed: 0, target: 50, rowAt: Self.rowAt(pointerY: 31))
        #expect(step == MinimapSnappedScroll.Step(rowID: "r8", offset: 0))
    }

    @Test func aRowChangeStepsToTheTarget() {
        let step = MinimapSnappedScroll.step(hoveredRowID: "r3", displayed: 0, target: 20, rowAt: Self.rowAt(pointerY: 36))
        #expect(step == MinimapSnappedScroll.Step(rowID: "r6", offset: 20))
    }

    @Test func theDeadZoneStillHoldsTheMap() {
        let frames = Self.run([150, 155, 140, 164, 137], snapped: true)
        #expect(Set(frames.map(\.displayed)) == [120])
        #expect(Set(frames.map(\.rowID)).count > 1)
    }
}
