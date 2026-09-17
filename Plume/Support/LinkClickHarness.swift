#if DEBUG
import AppKit
import OSLog

/// Clicks the first link in the chat from inside the process, so the hang in
/// `docs/selectable-text-link-hang.md` can be reproduced without the pointer
/// or the frontmost window. `PLUME_SYNTHETIC_LINK_CLICK=<seconds>` focuses
/// the composer and clicks after that delay; `PLUME_SYNTHETIC_LINK_CLICK_UNFOCUSED=1`
/// clicks with nothing focused, which is the control case.
@MainActor
enum LinkClickHarness {
    private static let log = Logger(subsystem: "com.ryanmoelter.Plume", category: "link-click")

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["PLUME_SYNTHETIC_LINK_CLICK"], let delay = TimeInterval(raw) else { return }
        let focusComposer = environment["PLUME_SYNTHETIC_LINK_CLICK_UNFOCUSED"] == nil
        Task {
            try? await Task.sleep(for: .seconds(delay))
            click(focusComposer: focusComposer)
        }
    }

    private static func click(focusComposer: Bool) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let root = window.contentView else {
            log.error("no visible window")
            return
        }
        if focusComposer, let composer = firstView(root, ofType: ComposerNSTextView.self) {
            window.makeFirstResponder(composer)
        } else {
            window.makeFirstResponder(nil)
        }
        guard let field = firstLinkField(in: root) else {
            log.error("no selectable text carrying a link")
            return
        }
        let inWindow = field.convert(field.bounds, to: nil)
        let textWidth = field.attributedStringValue.size().width
        let point = NSPoint(x: inWindow.minX + min(textWidth, inWindow.width) / 2, y: inWindow.midY)
        log.info("firstResponder=\(responderName(window), privacy: .public) clicking \(field.attributedStringValue.string.prefix(30), privacy: .public) at window \(NSStringFromPoint(point), privacy: .public)")

        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 4242, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Key without activating, so SwiftUI's focus system treats the window
        // as a real one. The up lands late enough for the tracking loop to
        // pump the run loop the way it does under a human click; queued
        // together, the loop exits before anything else can run.
        window.makeKey()
        NSApp.postEvent(down, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.postEvent(up, atStart: false) }
        Task {
            try? await Task.sleep(for: .seconds(1))
            log.info("one second later, still responsive; firstResponder=\(responderName(window), privacy: .public)")
        }
    }

    private static func firstLinkField(in root: NSView) -> NSControl? {
        var fields: [NSControl] = []
        collectSelectionFields(root, into: &fields)
        return fields.first { hasLink($0.attributedStringValue) }
    }

    private static func collectSelectionFields(_ view: NSView, into out: inout [NSControl]) {
        if let control = view as? NSControl, String(describing: type(of: view)).contains("SelectionTextField") {
            out.append(control)
        }
        for sub in view.subviews { collectSelectionFields(sub, into: &out) }
    }

    private static func firstView<T: NSView>(_ view: NSView, ofType: T.Type) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = firstView(sub, ofType: T.self) { return found }
        }
        return nil
    }

    private static func hasLink(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func responderName(_ window: NSWindow) -> String {
        window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    }
}
#endif
