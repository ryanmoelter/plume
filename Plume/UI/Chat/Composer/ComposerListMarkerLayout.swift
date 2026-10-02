import AppKit

/// The marker TextKit 2 would draw for a list item on the character-less last
/// line, which it never draws itself: `NSTextView` drops `textLists` from its
/// typing attributes, and that line has no paragraph of its own to carry them.
///
/// It lays a zero-width character out as a one-item list in a TextKit 2 stack
/// of its own. Drawing that fragment puts the marker's glyph, number and
/// position exactly where TextKit puts a real item's, and the end of its line
/// is where the item's first typed character will land.
@MainActor
final class ComposerListMarkerLayout {
    struct Layout {
        /// The one-item list. Its zero-width character draws nothing, so
        /// drawing the fragment draws only the marker.
        let fragment: NSTextLayoutFragment
        /// The fragment's origin relative to its line's typographic origin,
        /// for placing it on another line.
        let lineOffset: CGPoint
        /// How far past `lineFragmentPadding` the item's text starts.
        let textIndent: CGFloat
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var cached: (key: Key, layout: Layout)?

    private struct Key: Equatable {
        let kind: ComposerBlockKind
        let bodySize: CGFloat
        let width: CGFloat
        let padding: CGFloat
    }

    init() {
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
    }

    /// Nil for a kind that is not a list item.
    ///
    /// The item gets a list stack of its own rather than its neighbors': a
    /// marker depends only on the item's depth and format, and a fresh
    /// decimal list starts at the item's own number.
    func layout(for kind: ComposerBlockKind, style: ComposerTextStyle, width: CGFloat, padding: CGFloat) -> Layout? {
        guard kind.isList, width > 0 else { return nil }
        let key = Key(kind: kind, bodySize: style.bodySize, width: width, padding: padding)
        if let cached, cached.key == key { return cached.layout }

        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        container.lineFragmentPadding = padding
        let item = NSAttributedString(
            string: "\u{200B}",
            attributes: style.attributes(for: kind, lists: ComposerLists.lists(for: kind, continuing: []))
        )
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(item)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        guard let fragment = layoutManager.textLayoutFragment(for: layoutManager.documentRange.location),
              let line = fragment.textLineFragments.first
        else { return nil }
        // The line is the synthesized marker and its tabs, then the
        // zero-width character, so the line ends where the text starts.
        let textStart = fragment.layoutFragmentFrame.minX + line.typographicBounds.maxX
        let layout = Layout(
            fragment: fragment,
            lineOffset: CGPoint(
                x: fragment.layoutFragmentFrame.minX,
                y: -line.typographicBounds.minY
            ),
            textIndent: textStart - padding
        )
        cached = (key, layout)
        return layout
    }
}
