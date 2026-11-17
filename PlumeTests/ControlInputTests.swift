import AppKit
import SwiftUI
import Testing

@testable import Plume

/// The control server's input reaches AppKit views the way a person's does:
/// a click moves a text view's caret even in a window that isn't key, a
/// span scrolled out of view is scrolled in before it is clicked, the arrow
/// keys move the caret with and without Shift, and a live resize brackets
/// its sizes with `viewWillStartLiveResize` and `viewDidEndLiveResize`.
///
/// Needs a GUI session, like `ControlHierarchyTests`.
@MainActor
struct ControlInputTests {
    @Test func namedKeysAndCapitalsResolve() throws {
        let left = try InProcessControlBackend.shortcut(from: KeyParams(key: "left", modifiers: ["shift", "option"]))
        #expect(left.key == "\u{F702}")
        #expect(left.modifiers == [.shift, .option])
        #expect(SyntheticKey.keyCode(for: left.key) == 123)

        let capital = try InProcessControlBackend.shortcut(from: KeyParams(key: "A"))
        #expect(capital.modifiers == .shift)

        for name in ["up", "down", "right", "home", "end", "return", "tab", "escape", "forwarddelete"] {
            #expect(SyntheticKey.character(named: name) != nil, "\(name)")
        }
        #expect(throws: ControlError.self) { try InProcessControlBackend.shortcut(from: KeyParams(key: "leftish")) }
    }

    @Test func resizeDecodesAndClamps() throws {
        let request = try JSONDecoder().decode(
            ControlServerRequest.self,
            from: Data(#"{"id":"1","command":"resize","width":500,"height":400,"live":true,"steps":1000}"#.utf8)
        )
        guard case .resize(let params) = request.command else { Issue.record("not resize"); return }
        #expect(params == ResizeParams(width: 500, height: 400, live: true, steps: ResizeParams.stepLimit))
        let plain = try JSONDecoder().decode(ControlServerRequest.self, from: Data(#"{"id":"2","command":"resize","width":1,"height":2}"#.utf8))
        guard case .resize(let defaults) = plain.command else { Issue.record("not resize"); return }
        #expect(defaults.live == false && defaults.steps == 8)
    }

    /// One test rather than two: with no key window, AppKit sends a posted
    /// key to whichever window was last made key, so a parallel test's
    /// window would take this one's keys.
    @Test func clicksAndArrowKeysDriveAScrolledTextView() async throws {
        let (window, textView) = makeScrolledTextView()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let hit = try #require(TextSpanLocator.locate("needle 150", occurrence: 0, in: [textView], revealing: true))
        let center = CGPoint(x: hit.rectInWindow.midX, y: hit.rectInWindow.midY)
        #expect(hit.isVisible)
        #expect(SyntheticClick.hitView(at: center, in: window) === textView)

        await SyntheticClick.perform(at: center, in: window)
        let needle = (textView.string as NSString).range(of: "needle 150")
        #expect(await eventually { NSLocationInRange(textView.selectedRange().location, needle) }, "caret \(textView.selectedRange()), span \(needle)")

        let start = needle.location + 3
        textView.setSelectedRange(NSRange(location: start, length: 0))
        try await press("left", in: window)
        #expect(await eventually { textView.selectedRange() == NSRange(location: start - 1, length: 0) }, "\(textView.selectedRange())")
        try await press("right", modifiers: ["shift"], in: window)
        #expect(await eventually { textView.selectedRange() == NSRange(location: start - 1, length: 1) }, "\(textView.selectedRange())")
        try await press("down", in: window)
        #expect(await eventually { textView.selectedRange().location > NSMaxRange(needle) }, "\(textView.selectedRange())")
    }

    @Test func spansScrolledOutOfViewReportNotVisibleWithoutRevealing() async throws {
        let (window, textView) = makeScrolledTextView()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let hit = try #require(TextSpanLocator.locate("needle 150", occurrence: 0, in: [textView]))
        #expect(!hit.isVisible)
    }

    private func press(_ key: String, modifiers: [String] = [], in window: NSWindow) async throws {
        try await SyntheticKey.perform(try InProcessControlBackend.shortcut(from: KeyParams(key: key, modifiers: modifiers)), in: window)
    }

    @Test func aLiveResizeBracketsEverySize() async throws {
        let probe = LiveResizeProbe(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        probe.autoresizingMask = [.width, .height]
        let content = NSView(frame: probe.frame)
        content.addSubview(probe)
        let window = makeWindow(content: content, size: probe.frame.size)
        defer { window.close() }
        probe.log.removeAll()

        let result = try await InProcessControlBackend().resize(
            ResizeParams(width: 320, height: 300, windowNumber: window.windowNumber, live: true, steps: 4, stepDelay: 0)
        )
        #expect(result.width == 320 && result.sizes.count == 4)
        #expect(probe.log.first == "will")
        #expect(probe.log.last == "did")
        #expect(probe.log.dropFirst().dropLast().allSatisfy { $0.hasSuffix("live") }, "\(probe.log)")
        #expect(!window.inLiveResize)

        probe.log.removeAll()
        _ = try await InProcessControlBackend().resize(ResizeParams(width: 360, height: 300, windowNumber: window.windowNumber))
        #expect(probe.log == ["360"])
    }

    private final class LiveResizeProbe: NSView {
        var log: [String] = []

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            log.append("will")
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            log.append("did")
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            log.append("\(Int(newSize.width))" + (inLiveResize ? " live" : ""))
        }
    }

    /// A posted event is handled on a later run-loop pass than the one that
    /// posted it, and under a parallel test run that can be several.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeScrolledTextView() -> (NSWindow, NSTextView) {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let textView = scrollView.documentView as! NSTextView
        textView.string = (1...200).map { "line \($0) needle \($0)" }.joined(separator: "\n")
        return (makeWindow(content: scrollView, size: scrollView.frame.size), textView)
    }

    private func makeWindow(content: NSView, size: CGSize) -> NSWindow {
        content.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }
}
