import AppKit
import SwiftUI

/// A WYSIWYM-styled multiline text editor for the chat composer.
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
    var sendKey: ComposerSendKey
    var onSend: () -> Void
    /// Called on every keystroke, so the composer can react to the text
    /// without the text itself flowing through SwiftUI state per character.
    var onTextChange: (String) -> Void = { _ in }
    /// Called whenever the caret moves, from typing or arrow-key navigation
    /// alike — the slash-command autocomplete needs the caret's position,
    /// not just the text.
    var onCaretChange: (Int) -> Void = { _ in }
    /// Set to steer arrow/Tab/Escape/Return into the slash-command list
    /// while it's showing; nil (the default) leaves every key as-is.
    var autocompleteHandler: ComposerAutocompleteHandler?

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
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onCaretChange = onCaretChange
        textView.sendKey = sendKey
        textView.autocompleteHandler = autocompleteHandler

        // Only re-style and re-measure when something actually changed.
        // SwiftUI runs this on every update pass, and both the styling and
        // the height measurement are full passes over the text.
        if textView.string != text || context.coordinator.fontSize != fontSize {
            context.coordinator.apply(text: text, fontSize: fontSize, to: textView)
            view.invalidateContentHeight()
        }
        context.coordinator.updatePlaceholderVisibility(textView)

        if isFocused.wrappedValue, view.window?.firstResponder !== textView {
            view.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: isFocused,
            onSend: onSend,
            placeholder: placeholder,
            onTextChange: onTextChange,
            onCaretChange: onCaretChange
        )
    }

    /// macOS 26's reliable seam for an `NSViewRepresentable`'s size: SwiftUI
    /// does not treat AppKit's `intrinsicContentSize` as authoritative here,
    /// so growth/shrink as content changes must come from this instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScrollableComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: nsView.contentHeight(forWidth: width))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let textBinding: Binding<String>
        private let focusBinding: FocusState<Bool>.Binding
        var onSend: () -> Void
        var placeholder: String
        var onTextChange: (String) -> Void
        var onCaretChange: (Int) -> Void
        weak var host: ScrollableComposerTextView?
        weak var textView: ComposerNSTextView?
        private(set) var fontSize: CGFloat = 0

        init(
            text: Binding<String>,
            isFocused: FocusState<Bool>.Binding,
            onSend: @escaping () -> Void,
            placeholder: String,
            onTextChange: @escaping (String) -> Void,
            onCaretChange: @escaping (Int) -> Void = { _ in }
        ) {
            self.textBinding = text
            self.focusBinding = isFocused
            self.onSend = onSend
            self.placeholder = placeholder
            self.onTextChange = onTextChange
            self.onCaretChange = onCaretChange
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
            let bodyFont = NSFont.composerBody(ofSize: fontSize)
            textView.font = bodyFont
            textView.typingAttributes = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
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
            onTextChange(newText)
            MarkdownComposerStyler.style(textView.textStorage!, text: newText, fontSize: fontSize)
            updatePlaceholderVisibility(textView)
            host?.invalidateContentHeight()
            onCaretChange(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onCaretChange(textView.selectedRange().location)
        }

        func textDidBeginEditing(_ notification: Notification) {
            focusBinding.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            focusBinding.wrappedValue = false
        }

        func handleSendShortcut() {
            onSend()
        }
    }
}

/// Draws placeholder text directly rather than via a second overlay view,
/// and routes the configured send key to the composer's send action.
/// Whichever key sends, that same key with Shift always inserts a literal
/// newline — otherwise a multi-line message becomes impossible to type.
final class ComposerNSTextView: NSTextView {
    var placeholderText: String? {
        didSet { needsDisplay = true }
    }
    var sendKey: ComposerSendKey = .commandReturn
    weak var composerCoordinator: MarkdownComposerTextView.Coordinator?

    /// Consulted before Return/Tab/Escape/Up/Down are given their usual
    /// meaning, so the slash-command list can steer the caret and accept a
    /// selection without disturbing send-on-Return when it isn't showing.
    var autocompleteHandler: ComposerAutocompleteHandler?

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
        if let autocompleteHandler, autocompleteHandler.isShowing {
            switch event.keyCode {
            case 125 /* Down */:
                autocompleteHandler.moveSelection(by: 1)
                return
            case 126 /* Up */:
                autocompleteHandler.moveSelection(by: -1)
                return
            case 48 /* Tab */:
                autocompleteHandler.acceptSelection()
                return
            case 53 /* Escape */:
                autocompleteHandler.dismiss()
                return
            case 36 /* Return */:
                autocompleteHandler.acceptSelection()
                return
            default:
                break
            }
        }

        guard event.keyCode == 36 /* Return */ else {
            super.keyDown(with: event)
            return
        }

        let isCommand = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        switch sendKey {
        case .commandReturn:
            if isCommand {
                composerCoordinator?.handleSendShortcut()
                return
            }
        case .returnKey:
            if !isCommand, !isShift {
                composerCoordinator?.handleSendShortcut()
                return
            }
            if isShift, !isCommand {
                insertNewline(self)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// Steers the slash-command list from key events the text view intercepts.
/// `isShowing` gates interception itself — false means every key falls
/// through to the text view's normal behavior, send-on-Return included.
protocol ComposerAutocompleteHandler: AnyObject {
    var isShowing: Bool { get }
    func moveSelection(by delta: Int)
    func acceptSelection()
    func dismiss()
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
        composerTextView.textContainerInset = NSSize(width: 0, height: 9)
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

    /// Called when the text changes, since SwiftUI only re-asks
    /// `sizeThatFits` when something invalidates layout.
    func invalidateContentHeight() {
        cachedHeight = nil
        cachedKey = nil
        needsLayout = true
    }

    /// The measuring stack, built once and re-measured in place.
    ///
    /// SwiftUI asks `sizeThatFits` on every layout pass, not only when the
    /// text changes. Building an `NSLayoutManager` and copying the whole
    /// `NSTextStorage` per call put a full TextKit layout on the keystroke
    /// path, which is what made typing lag.
    private let measuringContainer = NSTextContainer()
    private let measuringLayoutManager = NSLayoutManager()
    private let measuringStorage = NSTextStorage()

    private var cachedHeight: CGFloat?
    private var cachedKey: MeasurementKey?

    private struct MeasurementKey: Equatable {
        let width: CGFloat
        let text: String
        let fontSize: CGFloat
    }

    /// The height for `width`, clamped between `minLines` and `maxLines`.
    ///
    /// `NSLayoutManager.usedRect` only reflects wrapping done at the text
    /// container's *current* width, which — before this view has been given
    /// its final SwiftUI-proposed width — can be stale or zero and reports a
    /// wildly wrong (often much taller) wrapped height. Setting the
    /// container's width explicitly before measuring is what makes this
    /// correct independent of AutoLayout's pass order.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let font = composerTextView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = font.boundingRectForFont.height
        let inset = composerTextView.textContainerInset
        let insets = inset.height * 2
        let minHeight = lineHeight * MarkdownComposerTextView.minLines + insets
        let maxHeight = lineHeight * MarkdownComposerTextView.maxLines + insets

        guard let storage = composerTextView.textStorage else { return minHeight }

        let key = MeasurementKey(width: width, text: storage.string, fontSize: font.pointSize)
        if key == cachedKey, let cachedHeight { return cachedHeight }

        if measuringLayoutManager.textContainers.isEmpty {
            measuringLayoutManager.addTextContainer(measuringContainer)
            measuringStorage.addLayoutManager(measuringLayoutManager)
            measuringContainer.lineFragmentPadding =
                composerTextView.textContainer?.lineFragmentPadding ?? 0
        }
        measuringContainer.size = NSSize(
            width: max(0, width - inset.width * 2),
            height: .greatestFiniteMagnitude
        )
        measuringStorage.setAttributedString(storage)
        measuringLayoutManager.ensureLayout(for: measuringContainer)

        let used = measuringLayoutManager.usedRect(for: measuringContainer).height + insets
        let height = min(max(used, minHeight), maxHeight)
        cachedKey = key
        cachedHeight = height
        return height
    }
}
