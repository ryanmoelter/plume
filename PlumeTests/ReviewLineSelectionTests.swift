import Foundation
import Testing

@testable import Plume

/// A gutter drag covers the rows from its line to the pointer's row, clamped
/// to the line rows of the file it started in, and the comment takes only
/// the lines in that range.
struct ReviewLineSelectionTests {
    /// `a` has two hunks of two lines, `b` is collapsed, `c` has one line:
    ///
    ///     0 header a   1 hunk   2 a1   3 a2   4 hunk   5 a10   6 a11
    ///     7 header b (collapsed)
    ///     8 header c   9 hunk   10 c1
    static let rows: [ReviewDocumentRow] = {
        func line(_ number: Int) -> DiffLine {
            DiffLine(kind: .added, text: "line \(number)", oldNumber: nil, newNumber: number)
        }
        func hunk(_ start: Int, _ numbers: [Int]) -> DiffHunk {
            DiffHunk(header: "@@ +\(start) @@", oldStart: 0, oldCount: 0, newStart: start, newCount: numbers.count, lines: numbers.map(line))
        }
        let a = ReviewDocument.segment(
            file: ReviewDocumentTests.file("a"),
            state: .loaded(ReviewDocument.body(for: .text([hunk(1, [1, 2]), hunk(10, [10, 11])]), path: "a"), version: 1),
            collapsed: false, comments: []
        )
        let b = ReviewDocumentTests.segment("b", lines: ["x"], collapsed: true)
        let c = ReviewDocumentTests.segment("c", lines: ["one"])
        return a.rows + b.rows + c.rows
    }()

    static func numbers(_ range: ClosedRange<Int>?) -> [Int] {
        range.map { ReviewLineSelection.lines(in: $0, of: rows).compactMap(\.newNumber) } ?? []
    }

    @Test func aPressWithoutMovingCoversItsOwnLine() {
        #expect(ReviewLineSelection.rows(from: 3, to: 3, in: Self.rows) == 3...3)
    }

    @Test func aDragCrossesAHunkHeaderInEitherDirection() {
        #expect(ReviewLineSelection.rows(from: 2, to: 5, in: Self.rows) == 2...5)
        #expect(Self.numbers(2...5) == [1, 2, 10])
        #expect(ReviewLineSelection.rows(from: 6, to: 3, in: Self.rows) == 3...6)
    }

    @Test func aDragOntoAHunkHeaderStopsAtTheLastLineBeforeIt() {
        #expect(ReviewLineSelection.rows(from: 6, to: 4, in: Self.rows) == 5...6)
    }

    @Test func aDragPastTheFileStopsAtItsFirstOrLastLine() {
        #expect(ReviewLineSelection.rows(from: 3, to: 0, in: Self.rows) == 2...3)
        #expect(ReviewLineSelection.rows(from: 3, to: 7, in: Self.rows) == 3...6)
        #expect(ReviewLineSelection.rows(from: 3, to: 10, in: Self.rows) == 3...6)
    }

    @Test func aDragUpFromALaterFileStopsBeforeACollapsedOne() {
        #expect(ReviewLineSelection.rows(from: 10, to: 0, in: Self.rows) == 10...10)
        #expect(ReviewLineSelection.rows(from: 10, to: 7, in: Self.rows) == 10...10)
    }

    @Test func aPointerBeyondTheDocumentClampsToItsEnds() {
        #expect(ReviewLineSelection.rows(from: 5, to: -40, in: Self.rows) == 2...5)
        #expect(ReviewLineSelection.rows(from: 5, to: 400, in: Self.rows) == 5...6)
    }

    @Test func onlyALineCanStartADrag() {
        #expect(ReviewLineSelection.rows(from: 1, to: 3, in: Self.rows) == nil)
        #expect(ReviewLineSelection.rows(from: 7, to: 7, in: Self.rows) == nil)
        #expect(ReviewLineSelection.rows(from: 99, to: 3, in: Self.rows) == nil)
    }

    @Test func aDraftCoversItsLinesInTheSegment() throws {
        let comment = try #require(ReviewComment(path: "a", lines: [
            DiffLine(kind: .added, text: "two", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .added, text: "three", oldNumber: nil, newNumber: 3),
        ]))
        let segment = ReviewDocument.segment(
            file: ReviewDocumentTests.file("a"),
            state: ReviewDocumentTests.loaded("a", lines: ["one", "two", "three", "four"]),
            collapsed: false,
            comments: [comment]
        )
        // header, hunk, 1, 2, 3, draft, 4
        #expect(segment.draftedRows == IndexSet(3...4))
    }
}
