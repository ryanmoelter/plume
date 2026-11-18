import Foundation
import Testing
@testable import Plume

/// The hover hovers the row under the pointer at the catch-up's offset, for
/// any pointer input. The drawn offset holds while the hovered row stays the
/// same, and on a change steps to the offset the catch-up would reach with
/// the pointer on the new row's middle.
@MainActor
struct MinimapSnappedScrollTests {
    private static let rowSpacing: CGFloat = 10
    private static let gain: CGFloat = 10
    /// 300 pt of rail over 700 pt of rows, so 400 pt of travel.
    private static let metrics = MinimapMetrics(height: 300, topMargin: 0, bottomInset: 0, contentHeight: 700)

    private static func rowIndex(atContentY y: CGFloat) -> Int {
        min(max(0, Int((y / rowSpacing).rounded())), 70)
    }

    private static func rowAt(pointerY: CGFloat) -> (CGFloat) -> String? {
        { offset in "r\(rowIndex(atContentY: pointerY + offset))" }
    }

    private static func pointer(atY y: CGFloat) -> CGFloat {
        MinimapCatchUp.absolute(pointerFraction: metrics.pointerFraction(atY: y))
    }

    private static func project(_ scroll: MinimapHoverScroll, pointerY: CGFloat, toRowAt rowY: CGFloat) -> CGFloat {
        MinimapSnappedScroll.projectedOffset(
            of: scroll,
            pointerY: pointerY,
            toRowAt: rowY,
            metrics: metrics,
            centering: 0,
            gain: gain
        )
    }

    private struct Frame: Equatable {
        var rowID: String?
        var displayed: CGFloat
        var target: CGFloat
    }

    /// Runs one pointer path through the catch-up, hovering through `step`.
    private static func run(_ path: [CGFloat], entryOffset: CGFloat = 120, deadZoneRadius: CGFloat = 16) -> [Frame] {
        guard let first = path.first else { return [] }
        var scroll = MinimapHoverScroll(
            offset: entryOffset,
            travel: metrics.travel,
            pointer: pointer(atY: first),
            gain: gain,
            entryY: first,
            deadZoneRadius: deadZoneRadius
        )
        var hovered: String?
        var displayed = entryOffset
        var frames: [Frame] = []
        for (index, y) in path.enumerated() {
            if index > 0 {
                scroll.move(to: pointer(atY: y), pointerY: y, travel: metrics.travel, gain: gain)
            }
            let current = scroll
            let step = MinimapSnappedScroll.step(
                hoveredRowID: hovered,
                displayed: displayed,
                target: scroll.offset,
                rowAt: rowAt(pointerY: y),
                project: { id in
                    let row = CGFloat(Int(id.dropFirst())!) * rowSpacing
                    return project(current, pointerY: y, toRowAt: row)
                }
            )
            hovered = step.rowID
            displayed = step.offset
            frames.append(Frame(rowID: hovered, displayed: displayed, target: scroll.offset))
        }
        return frames
    }

    /// A deterministic pointer wander inside the rail, mixing small jitters
    /// with longer sweeps.
    private static func wander(seed: UInt64, count: Int = 300) -> [CGFloat] {
        var state = seed
        var y: CGFloat = 150
        var path: [CGFloat] = []
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
            let reach: CGFloat = (state >> 20) & 7 == 0 ? 40 : 4
            y = min(max(y + (unit - 0.5) * 2 * reach, 0), 300)
            path.append(y)
        }
        return path
    }

    /// Monotone runs of fine moves, alternating direction, as a pointer
    /// sweeping up and down the rail does.
    private static func sweeps(seed: UInt64) -> [CGFloat] {
        var state = seed
        var y: CGFloat = 150
        var path: [CGFloat] = [y]
        for run in 0..<12 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let length = 20 + Int(state >> 58)
            let direction: CGFloat = run.isMultiple(of: 2) ? 1 : -1
            for _ in 0..<length {
                y = min(max(y + direction * 0.4, 0), 300)
                path.append(y)
            }
        }
        return path
    }

    nonisolated private static let seeds: [UInt64] = [1, 7, 42, 1234, 99_991, 31_337]

    @Test(arguments: seeds)
    func theHoveredRowIsTheOneUnderThePointerAtTheCatchUp(seed: UInt64) {
        for path in [Self.wander(seed: seed), Self.sweeps(seed: seed)] {
            for (y, frame) in zip(path, Self.run(path)) {
                #expect(frame.rowID == Self.rowAt(pointerY: y)(frame.target))
            }
        }
    }

    @Test(arguments: seeds)
    func theDrawnOffsetMovesOnlyWithTheHoveredRow(seed: UInt64) {
        let frames = Self.run(Self.wander(seed: seed))
        for (previous, frame) in zip(frames, frames.dropFirst()) where frame.rowID == previous.rowID {
            #expect(frame.displayed == previous.displayed)
        }
    }

    /// While a sweep stays on a row, the pointer stays over that row as
    /// drawn, so nothing under it disagrees with the hover; and the hover
    /// only ever moves to a neighbouring row.
    @Test(arguments: seeds)
    func aSweepKeepsTheHoveredRowUnderThePointer(seed: UInt64) {
        let path = Self.sweeps(seed: seed)
        let frames = Self.run(path, deadZoneRadius: 0)
        for (index, frame) in frames.enumerated() {
            #expect(Self.rowAt(pointerY: path[index])(frame.displayed) == frame.rowID)
            guard index > 0, let row = frame.rowID, let previous = frames[index - 1].rowID else { continue }
            #expect(abs(Int(row.dropFirst())! - Int(previous.dropFirst())!) <= 1)
        }
    }

    /// Half a row gap for the pointer's place within the row, plus however
    /// far one pointer move carries the content past the row's edge.
    @Test(arguments: seeds)
    func theDrawnOffsetStaysNearTheCatchUp(seed: UInt64) {
        for path in [Self.wander(seed: seed), Self.sweeps(seed: seed)] {
            for frame in Self.run(path) {
                #expect(abs(frame.displayed - frame.target) <= Self.rowSpacing)
            }
        }
    }

    @Test func theProjectionIsExactOnceLocked() {
        let scroll = MinimapHoverScroll(offset: 200, travel: 400, pointer: Self.pointer(atY: 150), gain: Self.gain)
        #expect(scroll.catchUp.isLocked)
        // Locked, the content under the pointer is y + 400 × (y / 300 − 0.05) / 0.9.
        let slope = 1 + 400 / (300 * 0.9)
        for row: CGFloat in [380, 300] {
            let y = (row + 400 * 0.05 / 0.9) / slope
            #expect(abs(Self.project(scroll, pointerY: 150, toRowAt: row) - (row - y)) < 0.01)
        }
    }

    @Test(arguments: [CGFloat(300), 240])
    func theProjectionFollowsTheCatchUp(row: CGFloat) {
        let scroll = MinimapHoverScroll(offset: 120, travel: 400, pointer: Self.pointer(atY: 150), gain: Self.gain)
        #expect(!scroll.catchUp.isLocked)
        var fine = scroll
        var y: CGFloat = 150
        let direction: CGFloat = row > y + fine.offset ? 1 : -1
        while (row - (y + fine.offset)) * direction > 0 {
            y += direction * 0.005
            fine.move(to: Self.pointer(atY: y), pointerY: y, travel: 400, gain: Self.gain)
        }
        let projected = Self.project(scroll, pointerY: 150, toRowAt: row)
        #expect(abs(projected - fine.offset) < 0.5)
        #expect((projected - 120) * direction > 0)
    }

    @Test func theFirstHoverTakesTheTarget() {
        let step = MinimapSnappedScroll.step(hoveredRowID: nil, displayed: 0, target: 12, rowAt: Self.rowAt(pointerY: 31), project: { _ in 99 })
        #expect(step == MinimapSnappedScroll.Step(rowID: "r4", offset: 12))
    }

    @Test func theDeadZoneStillHoldsTheMap() {
        let frames = Self.run([150, 156, 141, 164, 137])
        #expect(Set(frames.map(\.displayed)) == [120])
        #expect(Set(frames.map(\.rowID)).count > 2)
    }
}

/// Persisted tuning from a build that still had the snapped-scroll switch.
@MainActor
struct MinimapTuningTests {
    @Test func aStoredSnappedScrollKeyStillDecodes() {
        let defaults = UserDefaults(suiteName: "MinimapTuningTests.\(UUID().uuidString)")!
        defaults.set(["catchUpGain": 14.0, "snappedScroll": 1.0], forKey: "minimapTuning")

        let tuning = MinimapTuning(defaults: defaults)

        #if DEBUG
        #expect(tuning.values.catchUpGain == 14)
        #endif
        #expect(tuning.values.deadZoneRadius == MinimapTuning.Values.defaults.deadZoneRadius)
    }
}
