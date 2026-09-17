#if DEBUG
import AppKit
import OSLog

/// Records what the window hands out as its field editor when a click lands on
/// selectable chat text, to test whether the composer's own text view is being
/// reused as that editor — see PLUME-106.
///
/// Reads state only. It installs a monitor that observes events on their way to
/// the window and never consumes one, so the click it reports behaves exactly as
/// it would without the probe.
enum FieldEditorProbe {
    private static let log = Logger(subsystem: "com.ryanmoelter.Plume", category: "field-editor")
    private static var monitor: Any?

    static func install() {
        guard monitor == nil, ProcessInfo.processInfo.environment["PLUME_FIELD_EDITOR_PROBE"] != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            report(event)
            return event
        }
        log.info("field editor probe installed")
    }

    /// Logged before AppKit routes the click, so the field editor named here is
    /// the one the window holds going in. A hang leaves this as the last line
    /// written, which is what identifies the click that caused it.
    private static func report(_ event: NSEvent) {
        guard let window = event.window else { return }

        let responder = window.firstResponder
        let responderKind = responder.map { String(describing: type(of: $0)) } ?? "none"
        let isComposerFocused = responder is ComposerNSTextView

        // Asking with no client is what the text field's cell effectively does,
        // and the window answers with the editor it would supply.
        let editor = window.fieldEditor(false, for: nil)
        let editorKind = editor.map { String(describing: type(of: $0)) } ?? "none"
        let editorIsComposer = editor is ComposerNSTextView

        var sharesStorage = false
        var editorStorage = "none"
        var responderStorage = "none"
        if let editor = editor as? NSTextView {
            editorStorage = editor.textContentStorage.map { address(of: $0) } ?? "none"
            if let composer = responder as? NSTextView {
                responderStorage = composer.textContentStorage.map { address(of: $0) } ?? "none"
                sharesStorage = editor.textContentStorage === composer.textContentStorage
            }
        }

        log.info("""
            click at \(NSStringFromPoint(event.locationInWindow), privacy: .public) \
            responder=\(responderKind, privacy: .public) \
            composerFocused=\(isComposerFocused, privacy: .public) \
            fieldEditor=\(editorKind, privacy: .public) \
            editorIsComposer=\(editorIsComposer, privacy: .public) \
            editorStorage=\(editorStorage, privacy: .public) \
            responderStorage=\(responderStorage, privacy: .public) \
            sharesStorage=\(sharesStorage, privacy: .public)
            """)
    }

    private static func address(of object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object)), radix: 16)
    }
}
#endif
