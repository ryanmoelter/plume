import Foundation

/// Converts inline markdown (bold, italic, inline code, links — never block
/// structure) to and from the composer's attributed-run vocabulary.
nonisolated enum ComposerInlineMarkdown {
    /// Parses `markdown` with Foundation's inline-only parser and re-emits it
    /// as an `NSAttributedString` whose runs carry `kind`'s block attributes
    /// plus `.plumeInline`/`.plumeLink` for whatever formatting Foundation
    /// found. Falls back to the literal string — no formatting, but nothing
    /// lost — when the parser rejects the input outright.
    static func attributed(
        inline markdown: String,
        kind: ComposerBlockKind,
        style: ComposerTextStyle
    ) -> NSAttributedString {
        guard !markdown.isEmpty, let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: markdown, attributes: style.attributes(for: kind))
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            var inlineStyle: ComposerInlineStyle = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { inlineStyle.insert(.bold) }
                if intent.contains(.emphasized) { inlineStyle.insert(.italic) }
                if intent.contains(.code) { inlineStyle.insert(.code) }
            }
            let attributes = style.attributes(for: kind, inline: inlineStyle, link: run.link)
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// Serializes the inline runs of `range` back to markdown: a run walk
    /// over `.plumeInline`/`.plumeLink`, closing and reopening delimiters
    /// only where the style actually changes so overlapping spans nest
    /// correctly (`*before **both** after*`, never a bare run of asterisks
    /// long enough to be ambiguous). Never escapes anything — the message is
    /// read by an LLM, not a renderer, so a literal `*`, `_`, or backslash in
    /// the source text passes through untouched.
    static func markdown(from attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        var openStyles: [ComposerInlineStyle] = []
        var location = range.location
        let end = NSMaxRange(range)

        func close(until predicate: (ComposerInlineStyle) -> Bool) {
            while let top = openStyles.last, !predicate(top) {
                result += delimiter(for: top)
                openStyles.removeLast()
            }
        }

        while location < end {
            var inlineRange = NSRange(location: 0, length: 0)
            let style = (attributed.attribute(
                .plumeInline,
                at: location,
                longestEffectiveRange: &inlineRange,
                in: NSRange(location: location, length: end - location)
            ) as? ComposerInlineStyle) ?? []
            var linkRange = NSRange(location: 0, length: 0)
            let link = attributed.attribute(
                .plumeLink,
                at: location,
                longestEffectiveRange: &linkRange,
                in: NSRange(location: location, length: end - location)
            ) as? URL

            let runEnd = min(NSMaxRange(inlineRange), NSMaxRange(linkRange))
            let text = attributed.attributedSubstring(from: NSRange(location: location, length: runEnd - location)).string

            if style.contains(.code) || link != nil {
                close { _ in false }
                result += decorated(text, style: style, link: link)
            } else {
                let desired = style.intersection([.bold, .italic])
                close { desired.contains($0) }
                for candidate in nestingOrder where desired.contains(candidate) && !openStyles.contains(candidate) {
                    result += delimiter(for: candidate)
                    openStyles.append(candidate)
                }
                result += text
            }
            location = runEnd
        }

        close { _ in false }
        return result
    }

    /// Bold nests outside italic, so a run that opens both at once (no
    /// partial overlap with a neighbor) collapses to `***x***`; a run that
    /// only partially overlaps an already-open italic span nests properly
    /// instead, e.g. `*before **both** after*`.
    private static let nestingOrder: [ComposerInlineStyle] = [.bold, .italic]

    private static func delimiter(for style: ComposerInlineStyle) -> String {
        style == .bold ? "**" : "*"
    }

    /// A run with no open bold/italic: code and links are self-contained,
    /// each rendered without regard to any surrounding emphasis nesting.
    private static func decorated(_ text: String, style: ComposerInlineStyle, link: URL?) -> String {
        let inner = style.contains(.code) ? codeSpan(text) : text
        guard let link else { return inner }
        return "[\(inner)](\(link.absoluteString))"
    }

    /// CommonMark's rule: the fence is one backtick longer than the longest
    /// backtick run inside, and a span that starts or ends with a backtick
    /// gets a padding space on both sides so the fence doesn't visually
    /// merge with the content.
    private static func codeSpan(_ text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let content = (text.hasPrefix("`") || text.hasSuffix("`")) ? " \(text) " : text
        return fence + content + fence
    }
}
