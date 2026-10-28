import CoreGraphics

/// Converts AppKit scroll deltas into Android wheel units, 120 per notch.
nonisolated struct WheelAccumulator: Sendable {
    static let unitsPerNotch: CGFloat = 120
    static let pointsPerNotch: CGFloat = 40

    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0

    mutating func add(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool) -> (dx: Int32, dy: Int32) {
        guard hasPreciseDeltas else {
            return (Int32((deltaX * Self.unitsPerNotch).rounded()), Int32((deltaY * Self.unitsPerNotch).rounded()))
        }
        return (
            Self.drain(&remainderX, adding: deltaX),
            Self.drain(&remainderY, adding: deltaY)
        )
    }

    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private static func drain(_ remainder: inout CGFloat, adding delta: CGFloat) -> Int32 {
        remainder += delta
        let notches = (remainder / pointsPerNotch).rounded(.towardZero)
        remainder -= notches * pointsPerNotch
        return Int32(notches * unitsPerNotch)
    }
}
