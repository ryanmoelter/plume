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
        let paragraphs = ComposerParagraphs.all(in: storage)
        var previousLists: [NSTextList] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let kind = paragraph.kind
            let lists = ComposerLists.lists(for: kind, continuing: previousLists)
            previousLists = lists

            // An untagged neighbor never continues the block, even beside a
            // paragraph whose own missing tag reads as `.paragraph`.
            let paragraphStyle = style.paragraphStyle(
                for: kind.kind,
                isFirstInBlock: index == 0 || paragraphs[index - 1].storedKind != kind,
                isLastInBlock: index == paragraphs.count - 1 || paragraphs[index + 1].storedKind != kind,
                lists: lists
            )
            let current = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle
            if current == nil || !paragraphStyle.isEqual(current!) {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph.range)
            }
        }
    }
}
