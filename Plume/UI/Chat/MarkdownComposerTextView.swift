import AppKit
import SwiftUI

/// A true WYSIWYG markdown editor for the chat composer.
///
/// Wraps `NSTextView` because nothing in SwiftUI edits styled ranges of its own
/// text. The `NSTextStorage` **is** the document: `.plumeBlock`, `.plumeInline`
/// and `.plumeLink` carry the structure, no marker characters live in the text,
/// and `ComposerDocument` serializes the storage to markdown on every change.
/// The bound `String` is therefore markdown, not the characters on screen —
/// `onTextChange` is what hands out the visible text.
///
/// Literal markdown characters are never escaped on the way out. The message is
/// read by an LLM rather than rendered, so a path or a shell command the user
/// typed goes through exactly as typed; markers appear only for formatting that
/// was actually applied.
///
/// Grows with its content between `minLines` and `maxLines`, scrolling
/// internally beyond that.
struct MarkdownComposerTextView: NSViewRepresentable {
    /// The document as markdown. Reading it back in rebuilds the document, so
    /// the view only does that when the value differs from what it last
    /// emitted (or `resetGeneration` changed).
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    var isFocused: FocusState<Bool>.Binding
    var sendKey: ComposerSendKey
    var onSend: () -> Void
    /// Called on ⌥↩, when the caller has a third action for it. Nil (the
    /// default) leaves ⌥↩ inserting a newline as it otherwise would.
    var onOptionReturn: (() -> Void)?
    /// Called on every keystroke with the **visible** text — no markers, which
    /// is also the coordinate space the caret is reported in.
    var onTextChange: (String) -> Void = { _ in }
    /// Called whenever the caret moves, from typing or arrow-key navigation
    /// alike — the slash-command autocomplete needs the caret's position,
    /// not just the text.
    var onCaretChange: (Int) -> Void = { _ in }
    /// Bumped by the caller to force a reload when the markdown is unchanged —
    /// re-showing a draft the view itself last emitted, say.
    var resetGeneration: Int = 0
    /// Set by the caller to run a slash-command acceptance as an edit inside
    /// the view; cleared once applied.
    var pendingSlashCommand: Binding<SlashCommand?> = .constant(nil)
    /// Set to steer arrow/Tab/Escape/Return into the slash-command list
    /// while it's showing; nil (the default) leaves every key as-is.
    var autocompleteHandler: ComposerAutocompleteHandler?
    /// Called on Up when the composer is empty, to recall a queued message
    /// for editing. Nil when there's nothing queued.
    var onEditQueuedMessage: (() -> Void)?
    /// Names of the session's known slash commands, so a recognized leading
    /// `/name` token can be tinted as the user types it.
    var recognizedSlashCommandNames: Set<String> = []
    /// The attributed document to restore on mount, when the caller kept one.
    /// Literals are never escaped, so re-parsing the markdown draft would turn
    /// a pasted literal `**x**` bold on the way back in; the snapshot is what
    /// keeps it literal across an unmount.
    var restoredDocument: () -> NSAttributedString? = { nil }
    /// Called with a fresh snapshot after every change, for a caller that
    /// keeps one.
    var onDocumentChange: (NSAttributedString) -> Void = { _ in }

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
        context.coordinator.resetGeneration = resetGeneration
        context.coordinator.onDocumentChange = onDocumentChange
        context.coordinator.load(markdown: text, snapshot: restoredDocument(), fontSize: fontSize, into: textView)
        return view
    }

    func updateNSView(_ view: ScrollableComposerTextView, context: Context) {
        let textView = view.composerTextView
        let coordinator = context.coordinator
        coordinator.onSend = onSend
        coordinator.placeholder = placeholder
        coordinator.onTextChange = onTextChange
        coordinator.onCaretChange = onCaretChange
        coordinator.onDocumentChange = onDocumentChange
        textView.sendKey = sendKey
        textView.autocompleteHandler = autocompleteHandler
        textView.onEditQueuedMessage = onEditQueuedMessage
        textView.onOptionReturn = onOptionReturn

        let commandsChanged = coordinator.recognizedSlashCommandNames != recognizedSlashCommandNames
        coordinator.recognizedSlashCommandNames = recognizedSlashCommandNames

        if text != coordinator.lastEmittedMarkdown || resetGeneration != coordinator.resetGeneration {
            coordinator.resetGeneration = resetGeneration
            coordinator.load(markdown: text, snapshot: restoredDocument(), fontSize: fontSize, into: textView)
            view.invalidateContentHeight()
        } else if coordinator.fontSize != fontSize {
            coordinator.fontSize = fontSize
            textView.restyle(bodySize: fontSize)
            view.invalidateContentHeight()
        }
        if commandsChanged {
            textView.refreshCommandTint(names: recognizedSlashCommandNames)
        }
        if let command = pendingSlashCommand.wrappedValue {
            coordinator.acceptSlashCommand(command, clearing: pendingSlashCommand)
        }
        coordinator.updatePlaceholderVisibility(textView)

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
        var onDocumentChange: (NSAttributedString) -> Void = { _ in }
        weak var host: ScrollableComposerTextView?
        weak var textView: ComposerNSTextView?
        var fontSize: CGFloat = 0
        var recognizedSlashCommandNames: Set<String> = []
        var resetGeneration = 0
        /// The markdown this view last wrote to the binding. A value coming
        /// back that matches it is the view's own echo, not an external load.
        private(set) var lastEmittedMarkdown: String?
        /// The command an update pass has scheduled but not yet applied.
        private var pendingSlashCommand: SlashCommand?

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

        /// Rebuilds the document from outside the keystroke path. Prefers
        /// `snapshot` over parsing `markdown`, and tells the host what the
        /// visible text now is so a sendability flag starts out right.
        func load(markdown: String, snapshot: NSAttributedString?, fontSize: CGFloat, into textView: ComposerNSTextView) {
            self.fontSize = fontSize
            textView.style = ComposerTextStyle(bodySize: fontSize)
            textView.font = textView.style.body
            let document = snapshot ?? ComposerDocument.attributedString(markdown: markdown, style: textView.style)
            textView.loadDocument(document)
            lastEmittedMarkdown = markdown
            textView.refreshCommandTint(names: recognizedSlashCommandNames)
            updatePlaceholderVisibility(textView)
            let plain = textView.string
            let report = onTextChange
            DispatchQueue.main.async { report(plain) }
        }

        /// Applies an accepted slash command one turn later: accepting edits
        /// the document, which writes the binding back, and doing that inside
        /// an update pass mutates SwiftUI state mid-update and trips AppKit's
        /// layout engine.
        ///
        /// The command waits here rather than in the binding, and the block
        /// takes it before doing anything else — a second update pass before
        /// the block drains then finds nothing left to apply, instead of
        /// inserting the command twice.
        func acceptSlashCommand(_ command: SlashCommand, clearing binding: Binding<SlashCommand?>) {
            pendingSlashCommand = command
            DispatchQueue.main.async { [weak self] in
                guard let self, let command = pendingSlashCommand else { return }
                pendingSlashCommand = nil
                binding.wrappedValue = nil
                // The composer this was accepted in may be gone by now: a tab
                // switch replaces the text view, and a closed window leaves it
                // with none.
                guard let textView, textView.window != nil else { return }
                textView.acceptSlashCommand(command)
            }
        }

        func updatePlaceholderVisibility(_ textView: NSTextView) {
            (textView as? ComposerNSTextView)?.placeholderText = textView.string.isEmpty ? placeholder : nil
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            let markdown = textView.currentMarkdown
            lastEmittedMarkdown = markdown
            textBinding.wrappedValue = markdown
            onDocumentChange(textView.documentSnapshot)
            onTextChange(textView.string)
            textView.refreshCommandTint(names: recognizedSlashCommandNames)
            updatePlaceholderVisibility(textView)
            host?.invalidateContentHeight()
            onCaretChange(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            textView.typingInlineOverride = nil
            onCaretChange(textView.selectedRange().location)
        }

        /// The single seam for typing attributes, which AppKit asks about on
        /// edits and bare selection moves alike — see
        /// `ComposerNSTextView.desiredTypingAttributes()` for the rules.
        func textView(
            _ view: NSTextView,
            shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
            toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
        ) -> [NSAttributedString.Key: Any] {
            (view as? ComposerNSTextView)?.desiredTypingAttributes() ?? newTypingAttributes
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

        /// Text checking asks range by range, so the spans are read once per
        /// version of the document. Keyed on the revision rather than the
        /// string: applying inline code changes no characters at all.
        private var cachedCodeRanges: (revision: Int, ranges: [NSRange])?

        private func codeRanges(of view: NSTextView) -> [NSRange] {
            guard let composer = view as? ComposerNSTextView, let storage = composer.textStorage else { return [] }
            if let cachedCodeRanges, cachedCodeRanges.revision == composer.documentRevision {
                return cachedCodeRanges.ranges
            }
            let ranges = ComposerCodeRanges.codeRanges(in: storage)
            cachedCodeRanges = (composer.documentRevision, ranges)
            return ranges
        }
    }
}

/// Draws placeholder text and the composer's decorations directly rather than
/// via overlay views, keeps the document's structural invariants after every
/// edit, and routes the configured send key to the composer's send action.
/// Whichever key sends, that same key with Shift always inserts a literal
/// newline — otherwise a multi-line message becomes impossible to type.
///
/// `ComposerTextViewEditing.swift` holds the editing behavior.
final class ComposerNSTextView: NSTextView, NSTextStorageDelegate {
    var placeholderText: String? {
        didSet { needsDisplay = true }
    }
    var sendKey: ComposerSendKey = .commandReturn
    weak var composerCoordinator: MarkdownComposerTextView.Coordinator?

    /// The metrics `ComposerDecorations` draws chips, code boxes and quote
    /// bars with. The coordinator keeps it in step with the composer's font
    /// size; the default matches an unconfigured view.
    var style = ComposerTextStyle(bodySize: NSFont.systemFontSize) {
        didSet { needsDisplay = true }
    }

    /// The kind of the character-less line after the document's final newline.
    /// It holds no attributes of its own, so an operation that re-kinds it
    /// leaves the answer here until the first character lands.
    ///
    /// A selection that moves off that line abandons it — otherwise the
    /// marker of a list the user just selected and deleted would come back on
    /// the fresh line they start typing.
    var stickyKind: (kind: ComposerBlockKind, paragraphStart: Int)?

    /// True while `replace(_:with:selection:)` is moving the selection itself,
    /// so its own caret placement does not read as the user leaving the line.
    var isApplyingEdit = false

    /// The inline style ⌘B/⌘I chose for a collapsed selection, which
    /// `desiredTypingAttributes()` would otherwise re-derive from the
    /// characters around the caret and discard. Cleared by the next insertion
    /// or caret move.
    var typingInlineOverride: ComposerInlineStyle?

    /// Counts every edit the storage processes, characters or attributes
    /// alike — the height measurer's and the spell checker's cache key, since
    /// an attribute-only edit or an undo can change both without changing the
    /// text.
    private(set) var documentRevision = 0

    private var isObservingStorage = false
    private var isRepairingDocument = false

    /// Becomes its own storage's delegate, so every edit bumps
    /// `documentRevision`. Deliberately not done from an initializer:
    /// overriding `NSTextView.init(frame:)` sends AppKit back through its own
    /// designated initializer and overflows the stack, and the view it leaves
    /// behind has fallen back to TextKit 1.
    func observeStorage() {
        guard !isObservingStorage, let storage = textStorage else { return }
        storage.delegate = self
        isObservingStorage = true
    }

    override func layout() {
        super.layout()
        observeStorage()
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        documentRevision &+= 1
        if !isRepairingDocument {
            isRepairingDocument = true
            repairDocument(editedRange: editedRange)
            isRepairingDocument = false
        }
    }

    /// Re-establishes the document's structure after an edit: every paragraph
    /// tagged with one kind, numbered lists counting, and every paragraph style
    /// rebuilt from its kind — including the `NSTextList` stacks TextKit 2
    /// draws the markers from.
    ///
    /// It runs from the storage delegate on purpose. Attribute writes there
    /// register no undo action of their own, so an undo that restores
    /// characters gets its structure repaired without the repair itself
    /// becoming something to undo.
    private func repairDocument(editedRange: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        ComposerDocumentInvariants.normalize(storage, editedRange: editedRange, style: style)
        ComposerDocumentInvariants.renumber(storage, style: style)
        ComposerDocumentInvariants.padChips(storage, style: style)
        ComposerParagraphStyles.apply(to: storage, style: style)
    }

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

    /// Decorations and the placeholder are drawn here, not in `draw(_:)`.
    ///
    /// **Overriding `draw(_:)` on an `NSTextView` drops it to TextKit 1** —
    /// `textLayoutManager` comes back nil, and every piece of the composer
    /// that reads the TextKit 2 layout (decoration geometry above all) goes
    /// silently empty. `drawBackground(in:)` is the hook that keeps TextKit 2,
    /// and AppKit calls it even with `drawsBackground` false. It runs before
    /// the glyphs, which is where these belong anyway.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        ComposerDecorations.draw(in: self, style: style, dirtyRect: rect)

        // `style.body` rather than `self.font`, which follows the typing
        // attributes: an empty document whose line is a heading would
        // otherwise draw the placeholder at heading size.
        guard let placeholderText else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.body,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
        placeholderText.draw(at: origin, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        // An input method owns the keyboard while it is composing: Return and
        // the arrows belong to it, not to send, autocomplete or the input
        // rules.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b":
                toggleInline(.bold)
                return
            case "i":
                toggleInline(.italic)
                return
            case "v" where event.modifierFlags.contains(.option) && event.modifierFlags.contains(.shift):
                pasteAsMarkdown(self)
                return
            default:
                break
            }
        }

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
        composerTextView.observeStorage()
        // The document carries fonts and paragraph styles of its own, so the
        // view has to be rich — but none of AppKit's own formatting UI is
        // wanted: every style the composer has a name for is reachable from
        // the keyboard, and the rest would write attributes the model has no
        // way to represent.
        composerTextView.isRichText = true
        composerTextView.usesFontPanel = false
        composerTextView.usesRuler = false
        composerTextView.isRulerVisible = false
        composerTextView.usesInspectorBar = false
        composerTextView.importsGraphics = false
        composerTextView.allowsImageEditing = false
        composerTextView.isAutomaticTextCompletionEnabled = false
        composerTextView.allowsUndo = true
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
        // Marks live as layout-manager temporary attributes, so the
        // attribute repair pass over the text storage neither carries nor
        // erases them.
        composerTextView.isContinuousSpellCheckingEnabled = true
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
        measurer.invalidate()
        needsLayout = true
    }

    private lazy var measurer = ComposerHeightMeasurer(
        lineFragmentPadding: composerTextView.textContainer?.lineFragmentPadding ?? 0
    )

    /// The height for `width`, clamped between `minLines` and `maxLines`.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let font = composerTextView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = font.boundingRectForFont.height
        let inset = composerTextView.textContainerInset
        let insets = inset.height * 2
        let minHeight = lineHeight * MarkdownComposerTextView.minLines + insets
        let maxHeight = lineHeight * MarkdownComposerTextView.maxLines + insets

        guard let storage = composerTextView.textStorage else { return minHeight }

        measurer.emptyAttributes = composerTextView.typingAttributes
        let measured = measurer.height(
            for: storage,
            width: width,
            inset: inset,
            revision: composerTextView.documentRevision
        )
        return min(max(measured, minHeight), maxHeight)
    }
}
