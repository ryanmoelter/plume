import Foundation

/// The parts of a composer message that are code — inline spans and fenced
/// blocks — so text checking can leave them alone. A message is prose mixed
/// with identifiers, paths and shell commands, and spell-checking the code
/// half produces nothing but red underlines.
///
/// Ranges come from `MarkdownHighlighter`, which already answers "is this
/// code?" for styling, so there is one parser rather than two.
nonisolated enum ComposerCodeRanges {
    /// The code ranges in `text`, sorted and merged into disjoint runs.
    static func codeRanges(in text: String) -> [NSRange] {
        let raw = MarkdownHighlighter.spans(in: text)
            .filter { $0.style == .inlineCode || $0.style == .codeBlock }
            .map(\.range)
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

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
