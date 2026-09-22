import AppKit
import SwiftUI

/// Gives a sibling text field first responder once, with its contents
/// selected, so typing replaces what is there.
///
/// Focus is only ever taken, never given back: SwiftUI answers a programmatic
/// resign on a `.focused` binding by detaching whatever is first responder at
/// that moment, from inside a layout pass, which spins the main thread —
/// `docs/selectable-text-link-hang.md` has the trace. `MarkdownComposerTextView`
/// mirrors first responder by hand for the same reason.
///
/// Placed as a zero-size background behind the field it focuses, since it
/// reaches the field through the window rather than through a binding.
struct InitialFocus: NSViewRepresentable {
    /// Re-runs when this changes, for a field that appears after the sheet.
    var trigger: AnyHashable?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        focusSoon(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        focusSoon(from: view)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.lastTrigger = trigger
        return coordinator
    }

    final class Coordinator {
        var lastTrigger: AnyHashable?
    }

    /// The field has no window on the first layout pass, and taking first
    /// responder during one is what the hang above comes from, so this lands
    /// after the pass that created it.
    private func focusSoon(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard let field = Self.firstTextField(in: window.contentView) else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}
