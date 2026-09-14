import AppKit

/// Builds the `[NSTextList]` stack a list paragraph's paragraph style carries.
///
/// TextKit 2 synthesizes list markers from these objects — no marker
/// characters live in the storage, and the list itself supplies the indent,
/// so a list paragraph leaves `headIndent`/`firstLineHeadIndent` at 0.
///
/// Decimal numbering continues across paragraphs only while they share the
/// *same* `NSTextList` instance, which is why a caller walks the list in
/// order and threads each paragraph's result into the next call.
nonisolated enum ComposerLists {
    /// The list stack for a paragraph of `kind`, continuing `previous` (the
    /// stack the paragraph above produced, or `[]` to start a fresh list).
    ///
    /// Levels shallower than the paragraph's own depth are reused verbatim so
    /// an outer numbered list keeps counting across its nested items. The
    /// paragraph's own level is reused only when `previous` already had that
    /// depth with the same marker format; a new depth or a switch between
    /// bullets and numbers starts a new `NSTextList`, which restarts numbering
    /// at the paragraph's own number.
    static func lists(for kind: ComposerBlockKind, continuing previous: [NSTextList]) -> [NSTextList] {
        guard kind.isList else { return [] }
        let depth = kind.depth
        let format = markerFormat(for: kind)

        var result = Array(previous.prefix(depth))
        while result.count < depth {
            result.append(NSTextList(markerFormat: .disc, options: 0))
        }
        if previous.count > depth, previous[depth].markerFormat == format {
            result.append(previous[depth])
        } else {
            let list = NSTextList(markerFormat: format, options: 0)
            // TextKit counts from the list's own start, so a list that opens
            // at 3 has to say so or its markers disagree with the numbers
            // the same paragraphs serialize with.
            if case let .numbered(_, number) = kind.kind { list.startingItemNumber = number }
            result.append(list)
        }
        return result
    }

    /// Bullets cycle disc → circle → square by depth, the same ladder every
    /// nested list uses; numbered items are always decimal.
    static func markerFormat(for kind: ComposerBlockKind) -> NSTextList.MarkerFormat {
        switch kind.kind {
        case .numbered:
            return .decimal
        default:
            return bulletFormat(depth: kind.depth)
        }
    }

    static func bulletFormat(depth: Int) -> NSTextList.MarkerFormat {
        switch max(0, depth) % 3 {
        case 0: return .disc
        case 1: return .circle
        default: return .square
        }
    }
}
