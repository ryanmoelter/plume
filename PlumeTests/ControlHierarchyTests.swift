import AppKit
import SwiftUI
import Testing

@testable import Plume

/// Hosts real views in an `NSWindow` and checks what the control server sees:
/// `plumeID` registers a hosted SwiftUI control with a real frame, the text
/// dump names text and disabled controls and skips hidden views, and a
/// substring resolves to a rect inside its text view. None of it changes the
/// frontmost application.
///
/// Needs a GUI session, like `SurfaceCommandTests`; from a headless shell the
/// windows never lay out.
@MainActor
struct ControlHierarchyTests {
    @Test func plumeIDRegistersAHostedControlWithItsFrame() async throws {
        let registry = ControlRegistry.shared
        registry.removeAll()
        let host = NSHostingView(rootView:
            VStack {
                Text("x").plumeID("probe-text", label: "Probe")
                Button("Go") {}.plumeID("probe-button").disabled(true)
            }
            .frame(width: 200, height: 100)
        )
        let window = makeWindow(content: host, size: CGSize(width: 200, height: 100))
        defer { window.close() }
        try await settle()

        let text = try registry.resolve(.control(id: "probe-text", index: nil, label: nil))
        #expect(text.label == "Probe")
        #expect(text.frame.width > 0 && text.frame.height > 0)
        #expect(text.frame.minX >= 0 && text.frame.maxY <= 100)
        #expect(text.window === window)

        let button = try registry.resolve(.control(id: "probe-button", index: nil, label: nil))
        #expect(button.isEnabled == false)

        let backend = InProcessControlBackend(registry: registry)
        let dump = try backend.hierarchy(HierarchyParams(windowNumber: window.windowNumber))
        let rendered = try #require(dump.text)
        #expect(rendered.contains("control probe-text#0 label=\"Probe\""))
        #expect(rendered.contains("control probe-button#0") && rendered.contains("disabled"))
    }

    @Test func dumpReadsTextAndSkipsHiddenViews() throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let label = NSTextField(labelWithString: "hello")
        label.frame = CGRect(x: 10, y: 150, width: 100, height: 20)
        let button = NSButton(title: "Press", target: nil, action: nil)
        button.frame = CGRect(x: 10, y: 100, width: 100, height: 30)
        button.isEnabled = false
        let hidden = NSTextField(labelWithString: "secret")
        hidden.frame = CGRect(x: 10, y: 50, width: 100, height: 20)
        hidden.isHidden = true
        let plain = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        plain.addSubview(label)
        plain.addSubview(button)
        plain.addSubview(hidden)
        root.addSubview(plain)
        let window = makeWindow(content: root, size: CGSize(width: 300, height: 200))
        defer { window.close() }

        let node = HierarchyDumper.dump(root: root, controls: [], contentHeight: 200, textLimit: 200)
        let text = HierarchyDumper.render(node)
        #expect(text.contains("NSTextField \"hello\" (10,30 100×20)"))
        #expect(text.contains("NSButton \"Press\" (10,70 100×30) disabled"))
        #expect(!text.contains("secret"))
        #expect(node.children.allSatisfy { $0.kind != "NSView" }, "a plain container view collapses into its children")
    }

    @Test func aSubstringResolvesToARectInsideItsTextView() async throws {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        textView.string = "hello world, hello again"
        let window = makeWindow(content: textView, size: CGSize(width: 300, height: 60))
        defer { window.close() }
        try await settle()

        let first = try #require(TextSpanLocator.locate("hello", occurrence: 0, in: [textView]))
        let second = try #require(TextSpanLocator.locate("hello", occurrence: 1, in: [textView]))
        let frame = textView.convert(textView.bounds, to: nil)
        #expect(frame.contains(first.rectInWindow))
        #expect(frame.contains(second.rectInWindow))
        #expect(second.rectInWindow.minX > first.rectInWindow.maxX)
        #expect(TextSpanLocator.locate("absent", occurrence: 0, in: [textView]) == nil)

        await SyntheticClick.perform(at: CGPoint(x: first.rectInWindow.midX, y: first.rectInWindow.midY), in: window)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == before)
    }

    private func makeWindow(content: NSView, size: CGSize) -> NSWindow {
        content.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        // A programmatic window releases itself on close; ARC would then
        // release it a second time and crash inside a pending window animation.
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }

    /// Two run-loop turns: one for SwiftUI to lay out, one for the geometry
    /// and window callbacks that registration waits on.
    private func settle() async throws {
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
