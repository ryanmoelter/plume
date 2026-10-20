import Foundation
import Testing
@testable import Plume

struct MarkdownLineStructureTests {
    private func lines(_ text: String) -> [MarkdownLine] {
        MarkdownLineStructure.lines(in: text)
    }

    private func substring(_ text: String, _ range: NSRange?) -> String? {
        range.map { (text as NSString).substring(with: $0) }
    }

    @Test func bulletMarkerAndContentStart() {
        let text = "- item"
        let line = lines(text)[0]
        #expect(line.kind == .bullet)
        #expect(substring(text, line.marker) == "- ")
        #expect(line.contentStart == 2)
        #expect(line.atomicPrefix == NSRange(location: 0, length: 2))
    }

    @Test func orderedMarkerIsShownSoNotAtomic() {
        let line = lines("12) twelve")[0]
        #expect(line.kind == .ordered(number: 12))
        #expect(line.marker == NSRange(location: 0, length: 4))
        #expect(line.atomicPrefix == nil)
    }

    @Test func taskItems() {
        let text = "- [ ] open\n- [x] done\n- [y] not a task"
        let parsed = lines(text)
        #expect(parsed[0].kind == .task(isChecked: false))
        #expect(substring(text, parsed[0].marker) == "- [ ] ")
        #expect(substring(text, parsed[0].checkbox) == "[ ]")
        #expect(parsed[1].kind == .task(isChecked: true))
        #expect(parsed[2].kind == .bullet)
    }

    @Test func nestingDepthFollowsIndent() {
        let parsed = lines("- a\n  - b\n    - c\n  - d\n- e\n   1. f")
        #expect(parsed.map(\.depth) == [0, 1, 2, 1, 0, 1])
    }

    @Test func unindentedParagraphEndsTheList() {
        let parsed = lines("- a\ntext\n  - b")
        #expect(parsed[2].depth == 0)
    }

    @Test func blankLineKeepsTheList() {
        let parsed = lines("- a\n\n  - b")
        #expect(parsed[2].depth == 1)
    }

    @Test func nestedQuotes() {
        let text = "> > deep"
        let line = lines(text)[0]
        #expect(line.quoteLevel == 2)
        #expect(substring(text, line.atomicPrefix) == "> > ")
        #expect(line.kind == .plain)
    }

    @Test func listInsideQuote() {
        let text = "> - item"
        let line = lines(text)[0]
        #expect(line.quoteLevel == 1)
        #expect(line.kind == .bullet)
        #expect(substring(text, line.atomicPrefix) == "> - ")
    }

    @Test func headingMarkerIsShown() {
        let line = lines("## Title")[0]
        #expect(line.kind == .heading(level: 2))
        #expect(line.marker == NSRange(location: 0, length: 3))
        #expect(line.atomicPrefix == nil)
    }

    @Test func rulesBeatBullets() {
        for rule in ["---", "***", "___", "- - -", " * * *"] {
            #expect(lines(rule)[0].kind == .rule, "\(rule)")
        }
        #expect(lines("--")[0].kind == .plain)
        #expect(lines("- -")[0].kind == .bullet)
    }

    @Test func fencesNeedAnEqualOrLongerCloser() {
        let parsed = lines("````md\n```\ninner\n```\n````\nafter")
        #expect(parsed.map(\.kind) == [.fence, .code, .code, .code, .fence, .plain])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        let parsed = lines("```\n- not a list\n# not a heading")
        #expect(parsed.map(\.kind) == [.fence, .code, .code])
    }

    @Test func aQuoteMarkerInsideAFenceIsCode() {
        let parsed = lines("```\n>>> print(x)\n```")
        #expect(parsed[1].kind == .code)
        #expect(parsed[1].quoteLevel == 0)
        #expect(parsed[1].atomicPrefix == nil)
    }

    @Test func aQuotedFenceKeepsItsQuote() {
        let parsed = lines("> ```\n> > x\n> ```")
        #expect(parsed.map(\.kind) == [.fence, .code, .fence])
        #expect(parsed.map(\.quoteLevel) == [1, 1, 1])
    }

    @Test func trailingNewlineMakesAnEmptyLastLine() {
        let parsed = lines("- a\n")
        #expect(parsed.count == 2)
        #expect(parsed[1].range == NSRange(location: 4, length: 0))
        #expect(parsed[1].kind == .blank)
    }

    @Test func emptyTextHasOneLine() {
        #expect(lines("").count == 1)
    }

    @Test func utf16OffsetsAfterEmoji() {
        let text = "🎉\n- item"
        let line = lines(text)[1]
        #expect(line.range.location == 3)
        #expect(substring(text, line.marker) == "- ")
    }
}
