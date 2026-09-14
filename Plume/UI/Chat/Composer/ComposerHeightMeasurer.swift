import AppKit

/// Measures how tall the composer's text is at a given width, off to the side
/// of the live view.
///
/// SwiftUI asks `sizeThatFits` on every layout pass, not only when the text
/// changes, so the TextKit 2 stack is built once and re-measured in place and
/// the answer is cached on everything it depends on.
///
/// The stack mirrors the live view's `lineFragmentPadding`; its container
/// never tracks a view's width, and its width is set explicitly before every
/// measurement. That last part is load-bearing: a container still carrying a
/// stale or zero width lays the text out at that width and reports a wildly
/// wrong height, so the measurement must not depend on AutoLayout's pass
/// order.
@MainActor
final class ComposerHeightMeasurer {
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    private var cached: (key: Key, height: CGFloat)?

    private struct Key: Equatable {
        let width: CGFloat
        let fontSize: CGFloat
        let inset: NSSize
        let revision: Int
    }

    init(lineFragmentPadding: CGFloat) {
        container.lineFragmentPadding = lineFragmentPadding
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.maximumNumberOfLines = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
    }

    func invalidate() {
        cached = nil
    }

    /// The attributes an empty document's single line is laid out with —
    /// the live view's `typingAttributes`, so a font size change is visible
    /// even with nothing typed.
    var emptyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
    ]

    /// The laid-out height of `storage` at `width`, including `inset` on both
    /// the top and the bottom.
    ///
    /// `revision` is the caller's own edit counter, which is what makes an
    /// attribute-only edit (a re-style, an undo that changes no characters)
    /// invalidate the cache — the text alone cannot see those.
    ///
    /// An empty document has no layout fragment, and a document ending in a
    /// newline gets none for its empty last line, yet the live view leaves
    /// room for the caret on that line and counts it in
    /// `usageBoundsForTextContainer`. Measuring a zero-width sentinel on that
    /// line is what reproduces the live height rather than approximating it
    /// from font metrics.
    func height(for storage: NSTextStorage, width: CGFloat, inset: NSSize, revision: Int) -> CGFloat {
        let key = Key(width: width, fontSize: fontSize(of: storage), inset: inset, revision: revision)
        if let cached, cached.key == key { return cached.height }

        container.size = CGSize(width: max(0, width - inset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(measurable(storage))
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }

        let height = maxY + inset.height * 2
        cached = (key, height)
        return height
    }

    /// `storage` with a zero-width sentinel on the trailing empty line, when
    /// there is one.
    private func measurable(_ storage: NSTextStorage) -> NSAttributedString {
        guard storage.length == 0 || storage.string.hasSuffix("\n") else { return storage }
        let attributes = storage.length > 0
            ? storage.attributes(at: storage.length - 1, effectiveRange: nil)
            : emptyAttributes
        let result = NSMutableAttributedString(attributedString: storage)
        result.append(NSAttributedString(string: "\u{200B}", attributes: attributes))
        return result
    }

    private func fontSize(of storage: NSTextStorage) -> CGFloat {
        let font = storage.length > 0
            ? storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            : emptyAttributes[.font] as? NSFont
        return font?.pointSize ?? 0
    }
}
