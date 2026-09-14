import Foundation

/// The parts of a composer message that are code — inline spans and code
/// blocks — so text checking can leave them alone. A message is prose mixed
/// with identifiers, paths and shell commands, and spell-checking the code
/// half produces nothing but red underlines.
///
/// The document already knows which runs are code, so this reads the
/// attributes rather than re-parsing markdown that is no longer in the text.
nonisolated enum ComposerCodeRanges {
    /// The code ranges in `document`, sorted and merged into disjoint runs:
    /// `.plumeInline` runs carrying `.code`, plus whole paragraphs whose
    /// `.plumeBlock` is a code block or a verbatim construct.
    static func codeRanges(in document: NSAttributedString) -> [NSRange] {
        var raw: [NSRange] = []
        let full = NSRange(location: 0, length: document.length)
        document.enumerateAttribute(.plumeInline, in: full, options: []) { value, range, _ in
            guard let inline = value as? ComposerInlineStyle, inline.contains(.code) else { return }
            raw.append(range)
        }
        document.enumerateAttribute(.plumeBlock, in: full, options: []) { value, range, _ in
            guard let kind = value as? ComposerBlockKind else { return }
            switch kind.kind {
            case .codeBlock, .verbatim: raw.append(range)
            default: break
            }
        }
        raw = raw.filter { $0.length > 0 }.sorted { $0.location < $1.location }

        var merged: [NSRange] = []
        for range in raw {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The maximal ranges carrying inline code outside a code block or a
    /// verbatim construct — one range per chip. A span splits into several
    /// `.plumeInline` runs when something else changes inside it (a bold word,
    /// the kern on its last character), and those are one span, not several.
    static func inlineCodeSpans(in document: NSAttributedString) -> [NSRange] {
        var spans: [NSRange] = []
        let full = NSRange(location: 0, length: document.length)
        document.enumerateAttribute(.plumeInline, in: full, options: []) { value, range, _ in
            guard let inline = value as? ComposerInlineStyle, inline.contains(.code) else { return }
            let kind = document.attribute(.plumeBlock, at: range.location, effectiveRange: nil) as? ComposerBlockKind
            switch kind?.kind {
            case .codeBlock, .verbatim: return
            default: break
            }
            if let last = spans.last, NSMaxRange(last) == range.location {
                spans[spans.count - 1] = NSUnionRange(last, range)
            } else {
                spans.append(range)
            }
        }
        return spans
    }

    /// True when `range` overlaps any code at all. An empty range counts as
    /// overlapping when it sits strictly inside a code run.
    static func intersectsCode(_ range: NSRange, codeRanges: [NSRange]) -> Bool {
        codeRanges.contains { code in
            if range.length == 0 {
                return range.location > code.location && range.location < NSMaxRange(code)
            }
            return NSIntersectionRange(code, range).length > 0
        }
    }

    /// True when every character of `range` is code. Text checking picks its
    /// own ranges, which rarely line up with a span, so a range that only
    /// partly overlaps code is not entirely code.
    static func isEntirelyCode(_ range: NSRange, codeRanges: [NSRange]) -> Bool {
        guard range.length > 0 else { return intersectsCode(range, codeRanges: codeRanges) }
        return codeRanges.contains { NSIntersectionRange($0, range).length == range.length }
    }

    /// Drops the spelling and grammar results that land in code, keeping
    /// every other kind of result untouched.
    static func removingCodeResults(
        _ results: [NSTextCheckingResult],
        codeRanges: [NSRange]
    ) -> [NSTextCheckingResult] {
        guard !codeRanges.isEmpty else { return results }
        return results.filter { result in
            guard result.resultType == .spelling || result.resultType == .grammar else { return true }
            return !intersectsCode(result.range, codeRanges: codeRanges)
        }
    }
}
