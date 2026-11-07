import Foundation
import Testing
@testable import Plume

struct ReviewCommentBatchTests {
    @Test func eachCommentCarriesItsPathLinesAndAShortQuote() {
        let comments = [
            ReviewComment(path: "Sources/A.swift", side: .new, lines: 12...12, quote: ["    let x = 1"], body: "Rename x."),
            ReviewComment(
                path: "Sources/B.swift",
                side: .new,
                lines: 3...7,
                quote: ["a", "b", "c", "d", "e"],
                body: "  Extract this.\n"
            ),
            ReviewComment(path: "Sources/C.swift", side: .old, lines: 4...5, quote: ["gone", "too"], body: "Why remove?"),
            ReviewComment(path: "Sources/D.swift", side: .new, lines: 1...1, quote: ["x"], body: "   "),
        ]
        #expect(ReviewCommentBatch.message(comments) == """
        Review comments on the working tree. Address each one:

        `Sources/A.swift` line 12
        > let x = 1
        Rename x.

        `Sources/B.swift` lines 3–7
        > a
        > b
        > c
        > …
        Extract this.

        `Sources/C.swift` lines 4–5 (removed, numbered at the base)
        > gone
        > too
        Why remove?
        """)
    }

    @Test func aLongQuotedLineIsClipped() {
        let long = String(repeating: "x", count: 130)
        let message = ReviewCommentBatch.message([
            ReviewComment(path: "a", side: .new, lines: 1...1, quote: [long], body: "Shorter."),
        ])
        #expect(message.contains("> " + String(repeating: "x", count: 120) + "…\n"))
    }

    @Test func aRangeAnchorsOnTheNewSideUnlessEveryLineWasRemoved() throws {
        let mixed = try #require(ReviewComment(path: "a", lines: [
            DiffLine(kind: .removed, text: "old", oldNumber: 4, newNumber: nil),
            DiffLine(kind: .added, text: "new", oldNumber: nil, newNumber: 4),
            DiffLine(kind: .context, text: "same", oldNumber: 5, newNumber: 5),
        ]))
        #expect(mixed.side == .new)
        #expect(mixed.lines == 4...5)
        #expect(mixed.quote == ["old", "new", "same"])

        let removed = try #require(ReviewComment(path: "a", lines: [
            DiffLine(kind: .removed, text: "old", oldNumber: 9, newNumber: nil),
        ]))
        #expect(removed.side == .old)
        #expect(removed.endsAt(DiffLine(kind: .removed, text: "old", oldNumber: 9, newNumber: nil)))
        #expect(!removed.endsAt(DiffLine(kind: .context, text: "x", oldNumber: 9, newNumber: 10)))
    }
}
