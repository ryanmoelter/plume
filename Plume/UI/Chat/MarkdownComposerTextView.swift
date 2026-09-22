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
    /// Mirrors first-responder status, and claims it when set true.
    ///
    /// A plain binding rather than `FocusState`, on purpose. SwiftUI answers a
    /// programmatic `false` on a `.focused` binding by resigning whatever is
    /// first responder at that moment. During a click on selectable text that
    /// is the field editor whose mouse-tracking loop is still running, and
    /// detaching it mid-loop spins the main thread forever (PLUME-106).
    var isFocused: Binding<Bool>
    var sendKey: ComposerSendKey
    var onSend: () -> Void
    /// Called on ⌥↩, when the caller has a third action for it. Nil (the
    /// default) leaves ⌥↩ inserting a newline as it otherwise would.
    var onOptionReturn: (() -> Void)?
    /// Called on every keystroke, so the composer can react to the text
    /// without the text itself flowing through SwiftUI state per character.
    var onTextChange: (String) -> Void = { _ in }
    /// Called whenever the caret moves, from typing or arrow-key navigation
    /// alike — the slash-command autocomplete needs the caret's position,
    /// not just the text.
    var onCaretChange: (Int) -> Void = { _ in }
    /// Set by the caller to move the caret to a specific UTF-16 offset (e.g.
    /// after accepting a slash command); cleared once applied. Ordinary
    /// typing and arrow-key navigation never touch this — `apply(text:...)`
    /// otherwise preserves the existing selection across an external text
    /// change, which is the behavior this binding overrides.
    var pendingCaretLocation: Binding<Int?> = .constant(nil)
    /// Set to steer arrow/Tab/Escape/Return into the slash-command list
    /// while it's showing; nil (the default) leaves every key as-is.
    var autocompleteHandler: ComposerAutocompleteHandler?
    /// Called on Up when the composer is empty, to recall a queued message
    /// for editing. Nil when there's nothing queued.
    var onEditQueuedMessage: (() -> Void)?
    /// Names of the session's known slash commands, so a recognized leading
    /// `/name` token can be tinted as the user types it.
    var recognizedSlashCommandNames: Set<String> = []
    /// Called with images dropped on or pasted into the composer. Nil leaves
    /// both gestures to `NSTextView`.
    var onAttachImages: (([ChatImage]) -> Void)?
    /// Whether the draft is a shell command rather than a message: the whole
    /// field turns monospaced and no markdown is styled.
    var isCommandMode = false
    /// Called on Delete in an empty composer, so command mode can be left the
    /// way it was entered.
    var onDeleteBackwardWhenEmpty: (() -> Void)?

    static let minLines: CGFloat = 1
    static let maxLines: CGFloat = 8

    func makeNSView(context: Context) -> ScrollableComposerTextView {
        let view = ScrollableComposerTextView()
        context.coordinator.host = view
        let textView = view.composerTextView
        textView.delegate = context.coordinator
        textView.composerCoordinator = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.recognizedSlashCommandNames = recognizedSlashCommandNames
        context.coordinator.isCommandMode = isCommandMode
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
        textView.onEditQueuedMessage = onEditQueuedMessage
        textView.onOptionReturn = onOptionReturn
        textView.onAttachImages = onAttachImages
        textView.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty

        let commandsChanged = context.coordinator.recognizedSlashCommandNames != recognizedSlashCommandNames
        context.coordinator.recognizedSlashCommandNames = recognizedSlashCommandNames
        let modeChanged = context.coordinator.isCommandMode != isCommandMode
        context.coordinator.isCommandMode = isCommandMode

        // Only re-style and re-measure when something actually changed.
        // SwiftUI runs this on every update pass, and both the styling and
        // the height measurement are full passes over the text.
        if textView.string != text || context.coordinator.fontSize != fontSize || commandsChanged || modeChanged {
            context.coordinator.apply(text: text, fontSize: fontSize, to: textView)
            view.invalidateContentHeight()
        }
        if let location = pendingCaretLocation.wrappedValue {
            let clamped = min(location, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            DispatchQueue.main.async { pendingCaretLocation.wrappedValue = nil }
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
        private let focusBinding: Binding<Bool>
        var onSend: () -> Void
        var placeholder: String
        var onTextChange: (String) -> Void
        var onCaretChange: (Int) -> Void
        weak var host: ScrollableComposerTextView?
        weak var textView: ComposerNSTextView?
        private(set) var fontSize: CGFloat = 0
        var recognizedSlashCommandNames: Set<String> = []
        var isCommandMode = false

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
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
            let bodyFont = isCommandMode
                ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                : NSFont.composerBody(ofSize: fontSize)
            textView.font = bodyFont
            textView.typingAttributes = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
            MarkdownComposerStyler.style(
                textView.textStorage!,
                text: text,
                fontSize: fontSize,
                recognizedSlashCommandNames: recognizedSlashCommandNames,
                isCommandMode: isCommandMode
            )
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
            MarkdownComposerStyler.style(
                textView.textStorage!,
                text: newText,
                fontSize: fontSize,
                recognizedSlashCommandNames: recognizedSlashCommandNames,
                isCommandMode: isCommandMode
            )
            updatePlaceholderVisibility(textView)
            host?.invalidateContentHeight()
            onCaretChange(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onCaretChange(textView.selectedRange().location)
        }

        /// Driven from the text view's responder overrides rather than
        /// `textDidEndEditing`, which `NSTextView` posts only after the text
        /// changed, so a focus loss without typing would leave the binding
        /// stale and `updateNSView` would steal focus back.
        func focusDidChange(_ focused: Bool) {
            guard focusBinding.wrappedValue != focused else { return }
            focusBinding.wrappedValue = focused
        }

        func handleSendShortcut() {
            onSend()
        }

        // MARK: Text checking

        /// Spell checking skips code. Both routes to a red underline are
        /// covered: the text-checking API, which asks before and after it
        /// runs, and the indicator itself, which the text view sets through
        /// `shouldSetSpellingState`.
        func textView(
            _ view: NSTextView,
            willCheckTextIn range: NSRange,
            options: [NSSpellChecker.OptionKey: Any],
            types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
        ) -> [NSSpellChecker.OptionKey: Any] {
            if ComposerCodeRanges.isEntirelyCode(range, codeRanges: codeRanges(of: view)) {
                let spellingAndGrammar = NSTextCheckingResult.CheckingType.spelling.rawValue
                    | NSTextCheckingResult.CheckingType.grammar.rawValue
                checkingTypes.pointee &= ~spellingAndGrammar
            }
            return options
        }

        func textView(
            _ view: NSTextView,
            didCheckTextIn range: NSRange,
            types checkingTypes: NSTextCheckingTypes,
            options: [NSSpellChecker.OptionKey: Any],
            results: [NSTextCheckingResult],
            orthography: NSOrthography,
            wordCount: Int
        ) -> [NSTextCheckingResult] {
            ComposerCodeRanges.removingCodeResults(results, codeRanges: codeRanges(of: view))
        }

        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
            ComposerCodeRanges.intersectsCode(range, codeRanges: codeRanges(of: textView)) ? 0 : value
        }

        /// Text checking asks range by range, so the spans are parsed once
        /// per version of the text rather than once per question.
        private var cachedCodeRanges: (text: String, ranges: [NSRange])?

        private func codeRanges(of view: NSTextView) -> [NSRange] {
            let text = view.string
            if let cachedCodeRanges, cachedCodeRanges.text == text { return cachedCodeRanges.ranges }
            let ranges = ComposerCodeRanges.codeRanges(in: text)
            cachedCodeRanges = (text, ranges)
            return ranges
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

    /// Called on Up in an empty composer (and the autocomplete list isn't
    /// showing) so a queued message can be pulled back for editing —
    /// shell-history-style recall of the most recently queued send.
    var onEditQueuedMessage: (() -> Void)?

    /// Called on ⌥↩ instead of inserting a newline, for a caller with a third
    /// action on that key — the plan field's approve-with-feedback.
    var onOptionReturn: (() -> Void)?

    /// Called with images dropped on or pasted into the composer. Nil leaves
    /// both gestures to `NSTextView`'s own handling.
    var onAttachImages: (([ChatImage]) -> Void)?

    // MARK: - Image attachment

    /// Claims a drag only when it actually carries images, so a text drag
    /// still lands as an insertion.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesAttachableImages(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        carriesAttachableImages(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let images = attachableImages(on: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        onAttachImages?(images)
        return true
    }

    /// ⌘V routes here for every flavor, so images are intercepted before
    /// `NSTextView` turns them into an attachment inside the text storage —
    /// the composer's `String` binding has no way to carry one.
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let images = attachableImages(on: pasteboard)
        guard !images.isEmpty else { return super.readSelection(from: pasteboard) }
        onAttachImages?(images)
        return true
    }

    private func attachableImages(on pasteboard: NSPasteboard) -> [ChatImage] {
        guard onAttachImages != nil else { return [] }
        return ComposerImageAttachment.images(from: pasteboard)
    }

    private func carriesAttachableImages(_ pasteboard: NSPasteboard) -> Bool {
        onAttachImages != nil && ComposerImageAttachment.hasImages(on: pasteboard)
    }

    /// Called on Delete with nothing left to delete, so command mode can be
    /// backspaced out of the way the `!` that started it was typed.
    var onDeleteBackwardWhenEmpty: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { composerCoordinator?.focusDidChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { composerCoordinator?.focusDidChange(false) }
        return resigned
    }

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
        if let autocompleteHandler, autocompleteHandler.isShowing, !event.modifierFlags.contains(.command) {
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

        if event.keyCode == 51 /* Delete */, string.isEmpty, let onDeleteBackwardWhenEmpty {
            onDeleteBackwardWhenEmpty()
            return
        }

        if event.keyCode == 126 /* Up */, string.isEmpty, let onEditQueuedMessage {
            onEditQueuedMessage()
            return
        }

        guard event.keyCode == 36 /* Return */ else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.option), let onOptionReturn {
            onOptionReturn()
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
        // Nothing may rewrite what the user typed: a message is full of
        // identifiers, paths and shell commands that every substitution gets
        // wrong. Misspellings are marked and left alone.
        composerTextView.isAutomaticQuoteSubstitutionEnabled = false
        composerTextView.isAutomaticDashSubstitutionEnabled = false
        composerTextView.isAutomaticTextReplacementEnabled = false
        composerTextView.isAutomaticSpellingCorrectionEnabled = false
        composerTextView.isAutomaticLinkDetectionEnabled = false
        composerTextView.isAutomaticDataDetectionEnabled = false
        composerTextView.isGrammarCheckingEnabled = false
        // Marks live as layout-manager temporary attributes, so
        // `MarkdownComposerStyler`'s per-keystroke pass over the text storage
        // neither carries nor erases them.
        composerTextView.isContinuousSpellCheckingEnabled = true
        composerTextView.textContainerInset = NSSize(width: 0, height: 9)
        composerTextView.drawsBackground = false
        composerTextView.textContainer?.widthTracksTextView = true
        composerTextView.isVerticallyResizable = true
        composerTextView.isHorizontallyResizable = false
        composerTextView.autoresizingMask = [.width]
        // A plain-text view accepts only string drags, so image types have to
        // be asked for by name before a dropped file reaches the overrides.
        composerTextView.registerForDraggedTypes([.fileURL, .png, .tiff, .string])

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
