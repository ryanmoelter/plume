import AppKit
import SwiftUI
import Testing

@testable import Plume

/// Hosts real views in an `NSWindow` and checks what the control server sees:
/// `plumeID` registers a hosted SwiftUI control with a real frame, the text
/// dump names text and disabled controls and skips hidden views, a
/// substring resolves to a rect inside its text view, and a synthetic hover
/// reaches a `plumeHover` region and draws the overlay cursor. None of it
/// changes the frontmost application.
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
        // Other suites register into the same registry in parallel, so wait on
        // this window's ids rather than the total count.
        try await settle {
            ["probe-text", "probe-button"].allSatisfy { id in
                registry.entries(id: id).count == 1 && registry.entries(id: id).allSatisfy { $0.entry.window === window && $0.entry.frame.width > 0 }
            }
        }

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

    @Test func aScopedDumpLeavesOutControlsOutsideItsRoot() throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let panel = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 50))
        root.addSubview(panel)
        let window = makeWindow(content: root, size: CGSize(width: 300, height: 200))
        defer { window.close() }
        func entry(_ id: String, y: CGFloat) -> (index: Int, entry: ControlEntry) {
            (0, ControlEntry(token: UUID(), id: id, label: nil, value: nil, isEnabled: true, frame: CGRect(x: 10, y: y, width: 20, height: 10), window: window, invoke: nil, setValue: nil))
        }
        let controls = [entry("inside", y: 170), entry("outside", y: 20)]

        let scoped = HierarchyDumper.render(HierarchyDumper.dump(root: panel, controls: controls, contentHeight: 200, textLimit: 200))
        #expect(scoped.contains("inside"))
        #expect(!scoped.contains("outside"))
        let whole = HierarchyDumper.render(HierarchyDumper.dump(root: root, controls: controls, contentHeight: 200, textLimit: 200))
        #expect(whole.contains("inside") && whole.contains("outside"))
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

    @Test func syntheticHoverReachesAPlumeHoverRegionAndShowsTheOverlay() async throws {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let registry = HoverRegistry.shared
        registry.removeAll()
        let hovered = Hovered()
        let host = NSHostingView(rootView:
            VStack(spacing: 0) {
                Color.red.frame(width: 200, height: 50).plumeHover { hovered.top = $0; hovered.log.append("top \($0)") }
                Color.blue.frame(width: 200, height: 50).plumeHover { hovered.bottom = $0; hovered.log.append("bottom \($0)") }
            }
        )
        let window = makeWindow(content: host, size: CGSize(width: 200, height: 100))
        defer { window.close() }
        try await settle {
            let mine = registry.all.filter { $0.window === window }
            return mine.count == 2 && mine.allSatisfy { $0.frame.width > 0 }
        }

        SyntheticHover.move(to: CGPoint(x: 100, y: 75), in: window)
        #expect(hovered.top == true && hovered.bottom == false, "\(hovered.log)")
        let overlay = try #require(ControlOverlay.existing(for: window))
        #expect(window.childWindows?.count == 1)
        #expect(overlay.view.cursor == CGPoint(x: 100, y: 75))

        SyntheticHover.move(to: CGPoint(x: 100, y: 25), in: window)
        #expect(hovered.top == false && hovered.bottom == true, "\(hovered.log)")

        SyntheticHover.leave(window)
        #expect(hovered.top == false && hovered.bottom == false, "\(hovered.log)")
        overlay.remove()
        #expect(window.childWindows?.isEmpty ?? true)
        #expect(ControlOverlay.existing(for: window) == nil)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == before)
    }

    @MainActor
    private final class Hovered {
        var top = false
        var bottom = false
        var log: [String] = []
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

    /// Registration lands a few run-loop turns after the window shows, and
    /// later still when the whole test target runs alongside; poll for the
    /// registered state rather than sleeping a fixed time.
    private func settle(until ready: () -> Bool = { true }, deadline: Duration = .seconds(10)) async throws {
        let start = ContinuousClock.now
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            if ready() && ContinuousClock.now - start > .milliseconds(100) { return }
        } while ContinuousClock.now - start < deadline
        Issue.record("registration did not settle in \(deadline): controls=\(ControlRegistry.shared.entries().map { "\($0.entry.id) \($0.entry.frame) w=\($0.entry.window?.windowNumber ?? -1)" }) hovers=\(HoverRegistry.shared.all.map { "\($0.frame) w=\($0.window?.windowNumber ?? -1)" })")
    }
}
