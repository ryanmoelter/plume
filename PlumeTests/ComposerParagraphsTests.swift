import AppKit
import Foundation
import Testing
@testable import Plume

struct ComposerParagraphsTests {
    private static let style = ComposerTextStyle(bodySize: 14)

    @Test func emptyDocumentHasNoParagraphs() {
        #expect(ComposerParagraphs.all(in: NSAttributedString(string: "")).isEmpty)
    }

    @Test func trailingNewlineBelongsToTheRangeButNotTheContent() {
        let storage = NSAttributedString(string: "ab\ncd", attributes: Self.style.attributes(for: .quote))
        let paragraphs = ComposerParagraphs.all(in: storage)

        #expect(paragraphs.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 3, length: 2)])
        #expect(paragraphs.map(\.contentRange) == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        #expect(paragraphs.map(\.storedKind) == [.quote, .quote])
    }

    /// The line after a final newline has no characters to carry a kind, so it
    /// is not enumerated — `stickyKind` answers for it instead.
    @Test func characterlessLastLineIsNotAParagraph() {
        let storage = NSAttributedString(string: "a\n\n", attributes: Self.style.attributes(for: .paragraph))
        let paragraphs = ComposerParagraphs.all(in: storage)

        #expect(paragraphs.map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 1)])
        #expect(paragraphs.last?.contentRange == NSRange(location: 2, length: 0))
    }

    @Test func untaggedParagraphHasNoStoredKindButReadsAsParagraph() {
        let paragraphs = ComposerParagraphs.all(in: NSAttributedString(string: "plain"))
        #expect(paragraphs.first?.storedKind == nil)
        #expect(paragraphs.first?.kind == .paragraph)
    }

    @Test func withinARangeYieldsOnlyTheParagraphsItTouches() {
        let storage = NSAttributedString(string: "one\ntwo\nthree")
        let paragraphs = ComposerParagraphs.all(in: storage, within: NSRange(location: 4, length: 4))
        #expect(paragraphs.map(\.range) == [NSRange(location: 4, length: 4)])
    }

    @Test func sameLanguageCodeBlocksWithDifferentBlockIDsFormTwoRuns() {
        let first = ComposerBlockKind.codeBlock(language: "swift")
        let second = ComposerBlockKind.codeBlock(language: "swift")
        let storage = NSMutableAttributedString()
        storage.append(NSAttributedString(string: "a\nb\n", attributes: Self.style.attributes(for: first)))
        storage.append(NSAttributedString(string: "c\nd", attributes: Self.style.attributes(for: second)))

        let runs = ComposerParagraphs.runs(of: ComposerParagraphs.all(in: storage)) { $0.kind == $1.kind }

        #expect(runs.map(\.count) == [2, 2])
        #expect(runs.map { $0.first?.storedKind } == [first, second])
    }
}
