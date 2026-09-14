import AppKit
import Foundation
import Testing
@testable import Plume

/// The composer skips spell checking inside code. These cover which attributed
/// runs count as code, and how a checking range that only partly overlaps one
/// is treated.
@MainActor
struct ComposerCodeRangesTests {
    private let style = ComposerTextStyle(bodySize: 13)

    private func range(of substring: String, in text: String) -> NSRange {
        let found = (text as NSString).range(of: substring)
        precondition(found.location != NSNotFound, "substring not found")
        return found
    }

    /// Builds a document from `(text, inline style)` pairs under one block
    /// kind — the shape the storage actually carries, with no markers in it.
    private func document(
        _ pieces: [(String, ComposerInlineStyle)],
        kind: ComposerBlockKind = .paragraph
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, inline) in pieces {
            result.append(NSAttributedString(string: text, attributes: style.attributes(for: kind, inline: inline)))
        }
        return result
    }

    @Test func inlineCodeRunsAreCode() {
        let document = document([("run ", []), ("git worktree add", .code), (" first", [])])
        #expect(ComposerCodeRanges.codeRanges(in: document) == [NSRange(location: 4, length: 16)])
    }

    @Test func codeBlockParagraphsAreCode() {
        let block = document([("xcodebuild -scheme Plume", [])], kind: .codeBlock(language: nil))
        let result = NSMutableAttributedString(attributedString: document([("before\n", [])]))
        result.append(block)
        #expect(ComposerCodeRanges.codeRanges(in: result) == [NSRange(location: 7, length: 24)])
    }

    @Test func verbatimParagraphsAreCode() {
        let table = "| a | b |"
        let document = document([(table, [])], kind: .verbatim())
        #expect(ComposerCodeRanges.codeRanges(in: document) == [NSRange(location: 0, length: 9)])
    }

    @Test func proseHasNoCodeRanges() {
        #expect(ComposerCodeRanges.codeRanges(in: document([("just some ordinary prose", [])])).isEmpty)
    }

    @Test func adjacentSpansMerge() {
        // Two code runs meeting at one offset collapse into a single run.
        let document = document([("one", .code), ("two", .code)])
        #expect(ComposerCodeRanges.codeRanges(in: document) == [NSRange(location: 0, length: 6)])
    }

    @Test func rangeInsideCodeIsEntirelyCode() {
        let text = "run git worktree add first"
        let ranges = ComposerCodeRanges.codeRanges(in: document([("run ", []), ("git worktree add", .code), (" first", [])]))
        let inner = range(of: "worktree", in: text)
        #expect(ComposerCodeRanges.isEntirelyCode(inner, codeRanges: ranges))
        #expect(ComposerCodeRanges.intersectsCode(inner, codeRanges: ranges))
    }

    @Test func rangeStraddlingACodeBoundaryIsNotEntirelyCode() {
        let text = "run git worktree add first"
        let ranges = ComposerCodeRanges.codeRanges(in: document([("run ", []), ("git worktree add", .code), (" first", [])]))
        let straddling = range(of: "run git", in: text)
        #expect(!ComposerCodeRanges.isEntirelyCode(straddling, codeRanges: ranges))
        #expect(ComposerCodeRanges.intersectsCode(straddling, codeRanges: ranges))
    }

    @Test func proseRangeIsNeitherInsideNorTouchingCode() {
        let text = "run git worktree add first"
        let ranges = ComposerCodeRanges.codeRanges(in: document([("run ", []), ("git worktree add", .code), (" first", [])]))
        let prose = range(of: "first", in: text)
        #expect(!ComposerCodeRanges.isEntirelyCode(prose, codeRanges: ranges))
        #expect(!ComposerCodeRanges.intersectsCode(prose, codeRanges: ranges))
    }

    @Test func emptyRangeAtACodeEdgeDoesNotCount() {
        let ranges = ComposerCodeRanges.codeRanges(in: document([("run ", []), ("git", .code), (" first", [])]))
        #expect(!ComposerCodeRanges.intersectsCode(NSRange(location: 4, length: 0), codeRanges: ranges))
        #expect(ComposerCodeRanges.intersectsCode(NSRange(location: 5, length: 0), codeRanges: ranges))
    }

    @Test func spellingResultsInCodeAreDropped() {
        let text = "teh xcodebuild runs"
        let ranges = ComposerCodeRanges.codeRanges(in: document([("teh ", []), ("xcodebuild", .code), (" runs", [])]))
        let results = [
            NSTextCheckingResult.spellCheckingResult(range: range(of: "teh", in: text)),
            NSTextCheckingResult.spellCheckingResult(range: range(of: "xcodebuild", in: text)),
        ]
        let kept = ComposerCodeRanges.removingCodeResults(results, codeRanges: ranges)
        #expect(kept.map(\.range) == [range(of: "teh", in: text)])
    }

    @Test func nonSpellingResultsSurvive() {
        let text = "see https://example.com there"
        let ranges = ComposerCodeRanges.codeRanges(in: document([("see ", []), ("https://example.com", .code), (" there", [])]))
        let results = [NSTextCheckingResult.linkCheckingResult(
            range: range(of: "https://example.com", in: text),
            url: URL(string: "https://example.com")!
        )]
        #expect(ComposerCodeRanges.removingCodeResults(results, codeRanges: ranges).count == 1)
    }

    @Test func resultsPassThroughWhenThereIsNoCode() {
        let text = "teh quick brown fox"
        let results = [NSTextCheckingResult.spellCheckingResult(range: range(of: "teh", in: text))]
        #expect(ComposerCodeRanges.removingCodeResults(results, codeRanges: []).count == 1)
    }
}
