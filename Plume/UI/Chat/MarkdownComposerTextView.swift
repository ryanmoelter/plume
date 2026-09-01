import AppKit
import SwiftUI

/// A fixed-height, WYSIWYM-styled multiline text editor for the chat
/// composer.
///
/// Wraps `NSTextView` because `TextField` cannot style ranges of its own
/// text. `MarkdownHighlighter` finds the spans; this view only applies them
/// as attributes on `NSTextStorage` — the bound `String` is always exactly
/// what the user typed, with markers visible and merely styled in place.
///
/// Grows with its content between `minLines` and `maxLines`, scrolling
/// internally beyond that.
struct MarkdownComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var isFocused: FocusState<Bool>.Binding
    /// ⌘↩ sends; plain ↩ inserts a newline. See `ChatComposer`'s doc comment
    /// for why that split exists.
    var onSend: () -> Void

    static let minLines: CGFloat = 1
    static let maxLines: CGFloat = 8

    func makeNSView(context: Context) -> ScrollableComposerTextView {
        let view = ScrollableComposerTextView()
        context.coordinator.host = view
        let textView = view.composerTextView
        textView.delegate = context.coordinator
        textView.composerCoordinator = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.apply(text: text, fontSize: fontSize, to: textView)
        return view
    }

    func updateNSView(_ view: ScrollableComposerTextView, context: Context) {
        let textView = view.composerTextView
        context.coordinator.onSend = onSend
        context.coordinator.placeholder = placeholder

        if textView.string != text || context.coordinator.fontSize != fontSize {
            context.coordinator.apply(text: text, fontSize: fontSize, to: textView)
        }
        context.coordinator.updatePlaceholderVisibility(textView)
        view.invalidateContentHeight()

        if isFocused.wrappedValue, view.window?.firstResponder !== textView {
            view.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused, onSend: onSend, placeholder: placeholder)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let textBinding: Binding<String>
        private let focusBinding: FocusState<Bool>.Binding
        var onSend: () -> Void
        var placeholder: String
        weak var host: ScrollableComposerTextView?
        weak var textView: ComposerNSTextView?
        private(set) var fontSize: CGFloat = 0

        init(text: Binding<String>, isFocused: FocusState<Bool>.Binding, onSend: @escaping () -> Void, placeholder: String) {
            self.textBinding = text
            self.focusBinding = isFocused
            self.onSend = onSend
            self.placeholder = placeholder
        }

        /// Full re-style, used when the text or font size changes from
        /// outside a keystroke (initial mount, external `text` reset, font
        /// size change) as well as after every keystroke.
        func apply(text: String, fontSize: CGFloat, to textView: NSTextView) {
            self.fontSize = fontSize
            let selectedRanges = textView.selectedRanges
            if textView.string != text {
                textView.string = text
            }
            MarkdownComposerStyler.style(textView.textStorage!, text: text, fontSize: fontSize)
            textView.selectedRanges = selectedRanges
            updatePlaceholderVisibility(textView)
        }

        func updatePlaceholderVisibility(_ textView: NSTextView) {
            (textView as? ComposerNSTextView)?.placeholderText = textView.string.isEmpty ? placeholder : nil
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            textBinding.wrappedValue = newText
            MarkdownComposerStyler.style(textView.textStorage!, text: newText, fontSize: fontSize)
            updatePlaceholderVisibility(textView)
            host?.invalidateContentHeight()
        }

        func textDidBeginEditing(_ notification: Notification) {
            focusBinding.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            focusBinding.wrappedValue = false
        }

        /// ↩ inserts a newline (the text view's default); ⌘↩ sends instead.
        func handleSendShortcut() {
            onSend()
        }
    }
}

/// Draws placeholder text directly rather than via a second overlay view,
/// and routes ⌘↩ to the composer's send action while leaving every other
/// key — plain Return included — to `NSTextView`'s default handling, which
/// inserts a literal newline.
final class ComposerNSTextView: NSTextView {
    var placeholderText: String? {
        didSet { needsDisplay = true }
    }
    weak var composerCoordinator: MarkdownComposerTextView.Coordinator?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let placeholderText, let font = self.font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        placeholderText.draw(at: origin, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 /* Return */, event.modifierFlags.contains(.command) {
            composerCoordinator?.handleSendShortcut()
            return
        }
        super.keyDown(with: event)
    }
}

/// Hosts the text view in a scroll view sized to its content, between
/// `MarkdownComposerTextView.minLines` and `maxLines`.
final class ScrollableComposerTextView: NSView {
    let composerTextView = ComposerNSTextView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        composerTextView.isRichText = false
        composerTextView.isAutomaticQuoteSubstitutionEnabled = false
        composerTextView.isAutomaticDashSubstitutionEnabled = false
        composerTextView.isAutomaticTextReplacementEnabled = false
        composerTextView.isAutomaticSpellingCorrectionEnabled = true
        composerTextView.textContainerInset = NSSize(width: 0, height: 6)
        composerTextView.drawsBackground = false
        composerTextView.textContainer?.widthTracksTextView = true
        composerTextView.isVerticallyResizable = true
        composerTextView.isHorizontallyResizable = false
        composerTextView.autoresizingMask = [.width]

        scrollView.documentView = composerTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Called when the text changes, since AppKit caches the intrinsic size
    /// and will not re-ask on its own.
    func invalidateContentHeight() {
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let lineHeight = composerTextView.font?.boundingRectForFont.height ?? 16
        let insets = composerTextView.textContainerInset.height * 2
        let minHeight = lineHeight * MarkdownComposerTextView.minLines + insets
        let maxHeight = lineHeight * MarkdownComposerTextView.maxLines + insets

        // usedRect is only valid once layout has run for the whole container.
        guard let layoutManager = composerTextView.layoutManager,
              let container = composerTextView.textContainer
        else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minHeight)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + insets

        return NSSize(width: NSView.noIntrinsicMetric, height: min(max(used, minHeight), maxHeight))
    }
}
