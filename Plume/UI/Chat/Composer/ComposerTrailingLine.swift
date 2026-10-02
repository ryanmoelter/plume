import AppKit

/// The character-less last line after a document's final newline, as it is
/// laid out and drawn.
///
/// TextKit 2 lays that line out only as part of the last paragraph, and with
/// whatever attributes apply at that moment: the typing attributes while the
/// caret is on the line, otherwise the final newline's font and the last
/// paragraph's style. Nothing else re-lays it out — not a caret move, and not
/// a change of the line's kind, which has no character to edit. So:
///
/// - The typing attributes on that line are the line's own kind's.
/// - The final newline carries the line's font where it can (see
///   `giveFinalNewlineTheFont`), so a heading above doesn't make it
///   heading height.
/// - `layOutTrailingLine()` runs after every edit and every change of the
///   line's kind.
/// - The height measurer copies whichever attributes TextKit uses.
///
/// `NSTextView` also drops `textLists` from its typing attributes, so TextKit
/// never draws a list marker on that line. Its paragraph style carries the
/// list's text indent instead, and `ComposerDecorations` draws the marker.
extension ComposerNSTextView {
    /// Nil when the document ends in a character, so there is no such line.
    var trailingLineKind: ComposerBlockKind? {
        guard let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        guard ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A else { return nil }
        return paragraphInfo(at: ns.length).kind
    }

    func trailingLineAttributes(for kind: ComposerBlockKind) -> [NSAttributedString.Key: Any] {
        var attributes = style.attributes(for: kind)
        attributes[.paragraphStyle] = trailingLineParagraphStyle(for: kind)
        return attributes
    }

    /// A list item's style indents to where the item's text will start, with
    /// no `textLists`.
    func trailingLineParagraphStyle(for kind: ComposerBlockKind) -> NSParagraphStyle {
        guard kind.isList else { return style.paragraphStyle(for: kind.kind) }
        let indent = trailingListMarker(for: kind)?.textIndent ?? style.listIndent(depth: kind.depth)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent
        return paragraphStyle
    }

    func trailingListMarker(for kind: ComposerBlockKind) -> ComposerListMarkerLayout.Layout? {
        guard let container = textContainer else { return nil }
        return listMarkerLayout.layout(
            for: kind,
            style: style,
            width: container.size.width,
            padding: container.lineFragmentPadding
        )
    }

    /// Re-lays out the last paragraph, which holds the trailing line, and
    /// redraws it and re-measures the composer.
    func trailingLineDidChange() {
        layOutTrailingLine()
        composerCoordinator?.host?.invalidateContentHeight()
    }

    /// The attributes TextKit lays the trailing line out with, for the height
    /// measurer to copy.
    var trailingLineLayoutAttributes: [NSAttributedString.Key: Any]? {
        guard let kind = trailingLineKind, let storage = textStorage else { return nil }
        if isCommandMode { return typingAttributes }
        guard storage.length > 0, selectedRange().location < storage.length else {
            return trailingLineAttributes(for: kind)
        }
        return storage.attributes(at: storage.length - 1, effectiveRange: nil)
    }

    func layOutTrailingLine() {
        guard !isCommandMode, let kind = trailingLineKind,
              let storage = textStorage,
              let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage
        else { return }
        // Layout can't run inside the storage's own editing pass.
        guard storage.editedMask.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.layOutTrailingLine() }
            return
        }

        let lastParagraph = storage.length > 0
            ? (storage.string as NSString).paragraphRange(for: NSRange(location: storage.length - 1, length: 0))
            : NSRange(location: 0, length: 0)
        giveFinalNewlineTheFont(of: kind, lastParagraph: lastParagraph)
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: lastParagraph.location),
              let range = NSTextRange(location: start, end: contentStorage.documentRange.endLocation)
        else { return }

        layoutManager.invalidateLayout(for: range)
        layoutManager.ensureLayout(for: range)
        needsDisplay = true
    }

    /// The final newline's font sizes the trailing line whenever the caret is
    /// elsewhere. It is never larger than the last paragraph's own text,
    /// since it sits on that paragraph's line too, and an empty last
    /// paragraph keeps its own, because that newline is all that sizes the
    /// paragraph's line.
    private func giveFinalNewlineTheFont(of kind: ComposerBlockKind, lastParagraph: NSRange) {
        guard let storage = textStorage, lastParagraph.length > 1,
              let paragraphFont = storage.attribute(.font, at: lastParagraph.location, effectiveRange: nil) as? NSFont
        else { return }
        let newline = NSRange(location: storage.length - 1, length: 1)
        let trailingFont = style.font(for: kind.kind)
        let font = trailingFont.pointSize < paragraphFont.pointSize ? trailingFont : paragraphFont
        guard (storage.attribute(.font, at: newline.location, effectiveRange: nil) as? NSFont) != font else { return }
        storage.addAttribute(.font, value: font, range: newline)
    }
}
