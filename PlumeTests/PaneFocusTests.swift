import AppKit
import Testing
@testable import Plume

/// A view claims focus whenever it comes on screen in the focused pane, but
/// an on-screen pane gaining focus first checks whether a click already put
/// first responder inside it. The control server's `composer` and `chatList`
/// surfaces resolve only inside the focused pane.
@MainActor
struct PaneFocusTests {
    private typealias Claim = PaneFocusClaim

    @Test func anOnScreenPaneGainingFocusDefersToFirstResponder() {
        let old = Claim(isVisible: true, isFocused: false)
        #expect(Claim.defersToFirstResponder(from: old, to: Claim(isVisible: true, isFocused: true)))
    }

    @Test func aTabComingOnScreenClaimsOutright() {
        let old = Claim(isVisible: false, isFocused: false)
        #expect(!Claim.defersToFirstResponder(from: old, to: Claim(isVisible: true, isFocused: true)))
    }

    @Test func aViewRevealedInTheFocusedPaneClaimsOutright() {
        let old = Claim(isVisible: false, isFocused: true)
        #expect(!Claim.defersToFirstResponder(from: old, to: Claim(isVisible: true, isFocused: true)))
    }

    @Test func firstResponderIsFoundInsideItsPane() throws {
        let left = Focusable(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = Focusable(frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        content.addSubview(left)
        content.addSubview(right)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }

        try #require(window.makeFirstResponder(left))

        #expect(PaneAnchor.firstResponder(of: window, isWithin: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(!PaneAnchor.firstResponder(of: window, isWithin: CGRect(x: 100, y: 0, width: 100, height: 100)))
    }

    @Test func theFocusedPanesCandidateWins() {
        let candidates = [("left", CGRect(x: 0, y: 0, width: 100, height: 100)), ("right", CGRect(x: 101, y: 0, width: 100, height: 100))]
        let pane = CGRect(x: 101, y: 0, width: 100, height: 100)
        #expect(InProcessControlBackend.candidate(in: candidates, focusedPaneFrame: pane) == "right")
    }

    @Test func aLoneCandidateOutsideTheFocusedPaneIsNotFound() {
        let candidates = [("left", CGRect(x: 0, y: 0, width: 100, height: 100))]
        let pane = CGRect(x: 101, y: 0, width: 100, height: 100)
        #expect(InProcessControlBackend.candidate(in: candidates, focusedPaneFrame: pane) == nil)
    }

    @Test func withNoPaneTheFirstCandidateWins() {
        let candidates = [("only", CGRect(x: 0, y: 0, width: 100, height: 100))]
        #expect(InProcessControlBackend.candidate(in: candidates, focusedPaneFrame: nil) == "only")
    }

    /// Its `visibleRect` runs past its bounds, as an unclipped view's does.
    private final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
