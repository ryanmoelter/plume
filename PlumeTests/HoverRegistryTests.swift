import AppKit
import CoreGraphics
import Testing

@testable import Plume

/// The synthetic pointer enters and leaves `plumeHover` regions the way the
/// real one would: nested regions hover together, moving on un-hovers what
/// was left, and leaving the window clears everything in it.
@MainActor
struct HoverRegistryTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func movingThePointerEntersAndLeavesRegions() {
        let registry = HoverRegistry()
        let window = window()
        var log: [String] = []
        registry.register(HoverRegion(token: UUID(), frame: CGRect(x: 0, y: 0, width: 100, height: 100), window: window) { log.append("outer \($0)") })
        registry.register(HoverRegion(token: UUID(), frame: CGRect(x: 10, y: 10, width: 20, height: 20), window: window) { log.append("inner \($0)") })
        registry.register(HoverRegion(token: UUID(), frame: CGRect(x: 200, y: 0, width: 50, height: 50), window: window) { log.append("far \($0)") })

        #expect(registry.pointerMoved(to: CGPoint(x: 15, y: 15), in: window) == 2)
        #expect(log.sorted() == ["inner true", "outer true"])
        log = []
        #expect(registry.pointerMoved(to: CGPoint(x: 50, y: 50), in: window) == 1)
        #expect(log == ["inner false"])
        log = []
        #expect(registry.pointerMoved(to: CGPoint(x: 210, y: 10), in: window) == 1)
        #expect(log.sorted() == ["far true", "outer false"])
        log = []
        registry.pointerLeft(window)
        #expect(log == ["far false"])
        #expect(registry.hoveredCount == 0)
    }

    @Test func regionsInOtherWindowsAreIgnoredAndRemovedRegionsForgetTheirHover() {
        let registry = HoverRegistry()
        let a = window(), b = window()
        var hits = 0
        let token = UUID()
        registry.register(HoverRegion(token: token, frame: CGRect(x: 0, y: 0, width: 10, height: 10), window: a) { hits += $0 ? 1 : -1 })
        #expect(registry.pointerMoved(to: CGPoint(x: 5, y: 5), in: b) == 0)
        #expect(hits == 0)
        #expect(registry.pointerMoved(to: CGPoint(x: 5, y: 5), in: a) == 1)
        registry.remove(token: token)
        #expect(registry.hoveredCount == 0)
        registry.pointerLeftAll()
        #expect(hits == 1, "a removed region is not told it was left")
    }
}
