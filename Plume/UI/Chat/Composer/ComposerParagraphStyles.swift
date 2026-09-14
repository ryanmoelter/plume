import AppKit

/// Rewrites every paragraph's `.paragraphStyle` from the `.plumeBlock` kind it
/// already carries, list stacks included.
///
/// This is a whole-document pass rather than an edit-local one because none of
/// what it computes is local: a numbered list keeps counting only while its
/// paragraphs share one `NSTextList` instance, and a code block's padding
/// depends on which of its paragraphs is first and last. A composer draft is
/// short enough that walking all of it per edit costs nothing.
nonisolated enum ComposerParagraphStyles {
    static func apply(to storage: NSMutableAttributedString, style: ComposerTextStyle) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString

        var previousLists: [NSTextList] = []
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let kind = (storage.attribute(.plumeBlock, at: paragraph.location, effectiveRange: nil) as? ComposerBlockKind)
                ?? .paragraph

            let lists = ComposerLists.lists(for: kind, continuing: previousLists)
            previousLists = lists

            let paragraphStyle = style.paragraphStyle(
                for: kind.kind,
                isFirstInBlock: !continues(kind, fromParagraphBefore: paragraph.location, in: storage, ns: ns),
                isLastInBlock: !continues(kind, intoParagraphAfter: NSMaxRange(paragraph), in: storage, ns: ns),
                lists: lists
            )
            let current = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            if current == nil || !paragraphStyle.isEqual(current!) {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
            }

            location = NSMaxRange(paragraph)
        }
    }

    private static func continues(
        _ kind: ComposerBlockKind,
        fromParagraphBefore location: Int,
        in storage: NSMutableAttributedString,
        ns: NSString
    ) -> Bool {
        guard location > 0 else { return false }
        let before = ns.paragraphRange(for: NSRange(location: location - 1, length: 0))
        return neighborKind(at: before.location, in: storage) == kind
    }

    private static func continues(
        _ kind: ComposerBlockKind,
        intoParagraphAfter location: Int,
        in storage: NSMutableAttributedString,
        ns: NSString
    ) -> Bool {
        guard location < ns.length else { return false }
        return neighborKind(at: location, in: storage) == kind
    }

    private static func neighborKind(at location: Int, in storage: NSMutableAttributedString) -> ComposerBlockKind? {
        storage.attribute(.plumeBlock, at: location, effectiveRange: nil) as? ComposerBlockKind
    }
}
