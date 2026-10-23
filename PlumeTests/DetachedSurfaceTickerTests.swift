import Testing
@testable import Plume

/// Plume ticks ghostty itself only while terminals exist and none is in a
/// window; any attached terminal lets the wrapper's own wakeups do it.
struct DetachedSurfaceTickerTests {
    @Test func noTerminalsNeedNoTick() {
        #expect(!DetachedSurfaceTicker.needsTick(attachment: []))
    }

    @Test func terminalsAllInAnotherTaskNeedATick() {
        #expect(DetachedSurfaceTicker.needsTick(attachment: [false, false]))
    }

    @Test func oneAttachedTerminalLetsTheWrapperTick() {
        #expect(!DetachedSurfaceTicker.needsTick(attachment: [false, true, false]))
    }
}
