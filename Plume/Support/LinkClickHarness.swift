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
        if focusComposer, let composer = ViewFinder.first(ComposerNSTextView.self, in: root) {
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

        Task {
            await SyntheticClick.perform(at: point, in: window)
            try? await Task.sleep(for: .seconds(1))
            log.info("one second later, still responsive; firstResponder=\(responderName(window), privacy: .public)")
        }
    }

    private static func firstLinkField(in root: NSView) -> NSControl? {
        ViewFinder.selectionTextFields(in: root).first { hasLink($0.attributedStringValue) }
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
