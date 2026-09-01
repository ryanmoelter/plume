import Foundation
import Testing
@testable import Plume

/// `NSRange` locations are UTF-16 offsets; helpers below build expected
/// ranges from substrings so a test reads as "the range of this text" rather
/// than hand-counted offsets, which is what actually exercises multi-byte
/// characters correctly.
private extension String {
    func range(of substring: String, occurrence: Int = 0) -> NSRange {
        let ns = self as NSString
        var searchStart = 0
        var found: NSRange = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
            found = ns.range(of: substring, range: searchRange)
            precondition(found.location != NSNotFound, "substring not found")
            searchStart = found.location + 1
        }
        return found
    }
}

struct MarkdownHighlighterTests {
    @Test func bold() {
        let text = "before **bold** after"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "**", occurrence: 0), style: .bold)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "bold"), style: .bold)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "**", occurrence: 1), style: .bold)))
    }

    @Test func italicAsterisk() {
        let text = "before *italic* after"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "*", occurrence: 0), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "italic"), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "*", occurrence: 1), style: .italic)))
    }

    @Test func italicUnderscore() {
        let text = "before _italic_ after"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "_", occurrence: 0), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "italic"), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "_", occurrence: 1), style: .italic)))
    }

    @Test func inlineCode() {
        let text = "before `code` after"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "`code`"), style: .inlineCode)))
    }

    @Test func fencedCodeBlock() {
        let text = "```swift\nlet x = 1\n```"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: NSRange(location: 0, length: (text as NSString).length), style: .codeBlock)))
    }

    @Test func headingLevels() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let text = "\(hashes) Title"
            let spans = MarkdownHighlighter.spans(in: text)
            #expect(spans.contains(MarkdownHighlighter.Span(
                range: NSRange(location: 0, length: level + 1),
                style: .heading(level: level)
            )), "level \(level) marker")
            #expect(spans.contains(MarkdownHighlighter.Span(
                range: text.range(of: "Title"),
                style: .heading(level: level)
            )), "level \(level) content")
        }
    }

    @Test func headingRequiresSpaceAfterHashes() {
        let text = "#NotAHeading"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { if case .heading = $0.style { return true }; return false })
    }

    @Test func bulletListMarkers() {
        for marker in ["-", "*", "+"] {
            let text = "\(marker) item one"
            let spans = MarkdownHighlighter.spans(in: text)
            #expect(spans.contains(MarkdownHighlighter.Span(
                range: NSRange(location: 0, length: 2),
                style: .listMarker
            )), "marker \(marker)")
        }
    }

    @Test func numberedListMarker() {
        let text = "12. item"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(
            range: NSRange(location: 0, length: 4),
            style: .listMarker
        )))
    }

    @Test func blockQuoteMarker() {
        let text = "> quoted text"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: NSRange(location: 0, length: 1), style: .blockQuote)))
    }

    @Test func link() {
        let text = "see [the docs](https://example.com) for more"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(
            range: text.range(of: "[the docs](https://example.com)"),
            style: .link
        )))
    }

    // MARK: - Edge cases

    @Test func unterminatedBoldStylesNothing() {
        let text = "this is **bold with no closer"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.isEmpty)
    }

    @Test func unterminatedBoldDoesNotRunToEndOfDocument() {
        let text = "**start\nmore text\nand more"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .bold })
    }

    @Test func markersInsideFencedCodeBlockAreLiteral() {
        let text = "```\n**not bold** and `not code`\n```"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .bold })
        #expect(!spans.contains { $0.style == .inlineCode })
        #expect(spans.contains { $0.style == .codeBlock })
    }

    @Test func markersInsideInlineCodeAreLiteral() {
        let text = "text `**not bold**` more"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .bold })
        #expect(spans.contains { $0.style == .inlineCode })
    }

    @Test func escapedAsteriskIsNotItalic() {
        let text = #"\*not italic\*"#
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .italic })
    }

    @Test func escapedBoldMarkerIsNotBold() {
        let text = #"\*\*not bold\*\*"#
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .bold })
    }

    @Test func emptyBoldStylesNothing() {
        let text = "before **** after"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .bold })
    }

    @Test func emptyInlineCodeStylesNothing() {
        let text = "before `` after"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(!spans.contains { $0.style == .inlineCode })
    }

    @Test func multiByteCharacterBeforeMarkerKeepsOffsetsAligned() {
        // "café 🎉 " precedes the marker with a combining-adjacent accented
        // letter and a surrogate-pair emoji, exercising UTF-16 offset math.
        let text = "café 🎉 **bold** done"
        let spans = MarkdownHighlighter.spans(in: text)
        let ns = text as NSString

        let openRange = text.range(of: "**", occurrence: 0)
        let contentRange = text.range(of: "bold")
        let closeRange = text.range(of: "**", occurrence: 1)

        #expect(spans.contains(MarkdownHighlighter.Span(range: openRange, style: .bold)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: contentRange, style: .bold)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: closeRange, style: .bold)))
        #expect(ns.substring(with: openRange) == "**")
        #expect(ns.substring(with: contentRange) == "bold")
    }

    @Test func nestedItalicInsideBold() {
        // "**bold *and italic* text**": the lone `*` at index 7 opens italic,
        // the lone `*` at index 18 closes it; the outer `**`/`**` (bold) wrap
        // the whole thing.
        let text = "**bold *and italic* text**"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: NSRange(location: 7, length: 1), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "and italic"), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: NSRange(location: 18, length: 1), style: .italic)))
        #expect(spans.contains(MarkdownHighlighter.Span(range: text.range(of: "bold *and italic* text"), style: .bold)))
    }

    @Test func indentedListMarkerStillDetected() {
        let text = "  - indented item"
        let spans = MarkdownHighlighter.spans(in: text)
        #expect(spans.contains(MarkdownHighlighter.Span(range: NSRange(location: 2, length: 2), style: .listMarker)))
    }
}
