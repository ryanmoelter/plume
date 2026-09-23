import AppKit
import SwiftUI

/// A field that captures the next chord the user presses and reports it as a
/// `MenuShortcut`.
///
/// Recording has to happen in AppKit: SwiftUI delivers key presses only
/// through `.onKeyPress`, which reports characters rather than the raw
/// modifier set, and the chords worth binding here (⌥⇧J) are exactly the ones
/// that compose to a different character.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: MenuShortcut?
    let onRecord: (MenuShortcut) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
        view.shortcut = shortcut
    }

    final class RecorderView: NSView {
        var onRecord: ((MenuShortcut) -> Void)?

        var shortcut: MenuShortcut? {
            didSet { needsDisplay = true }
        }

        private var isRecording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        /// Claims the chord before the menu does. A recorder that let
        /// `performKeyEquivalent` run first could never capture a chord that
        /// is already bound — including the one it is being asked to replace.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return false }
            return record(event)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording, record(event) else {
                super.keyDown(with: event)
                return
            }
        }

        private func record(_ event: NSEvent) -> Bool {
            // Escape abandons recording rather than binding itself.
            if event.keyCode == 53 {
                isRecording = false
                window?.makeFirstResponder(nil)
                return true
            }

            let modifiers = MenuShortcut.eventModifiers(
                MenuShortcut.deviceIndependentFlags(event.modifierFlags)
            )
            guard
                !modifiers.isEmpty,
                let characters = event.charactersIgnoringModifiers?.lowercased(),
                let key = characters.first,
                characters.count == 1
            else {
                return false
            }

            onRecord?(MenuShortcut(key, modifiers: modifiers))
            isRecording = false
            window?.makeFirstResponder(nil)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            rounded.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            rounded.stroke()

            let text = isRecording ? "Press a chord…" : (shortcut?.displayName ?? "Unassigned")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: shortcut == nil && !isRecording ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
