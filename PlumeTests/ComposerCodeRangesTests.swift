import Foundation
import Testing
@testable import Plume

/// The composer skips spell checking inside code. These cover which ranges
/// count as code, and how a checking range that only partly overlaps one is
/// treated.
struct ComposerCodeRangesTests {
    private func range(of substring: String, in text: String) -> NSRange {
        let found = (text as NSString).range(of: substring)
        precondition(found.location != NSNotFound, "substring not found")
        return found
    }

    @Test func inlineCodeSpanIsCode() {
        let text = "run `git worktree add` first"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        #expect(ranges == [range(of: "`git worktree add`", in: text)])
    }

    @Test func fencedBlockIsCode() {
        let text = "before\n```\nxcodebuild -scheme Plume\n```\nafter"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        #expect(ranges == [range(of: "```\nxcodebuild -scheme Plume\n```", in: text)])
    }

    @Test func proseHasNoCodeRanges() {
        #expect(ComposerCodeRanges.codeRanges(in: "just some ordinary prose").isEmpty)
    }

    @Test func adjacentSpansMerge() {
        let text = "`one``two`"
        // Two spans meeting at one offset collapse into a single run.
        #expect(ComposerCodeRanges.codeRanges(in: text) == [NSRange(location: 0, length: 10)])
    }

    @Test func rangeInsideCodeIsEntirelyCode() {
        let text = "run `git worktree add` first"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        let inner = range(of: "worktree", in: text)
        #expect(ComposerCodeRanges.isEntirelyCode(inner, codeRanges: ranges))
        #expect(ComposerCodeRanges.intersectsCode(inner, codeRanges: ranges))
    }

    @Test func rangeStraddlingACodeBoundaryIsNotEntirelyCode() {
        let text = "run `git worktree add` first"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        let straddling = range(of: "run `git", in: text)
        #expect(!ComposerCodeRanges.isEntirelyCode(straddling, codeRanges: ranges))
        #expect(ComposerCodeRanges.intersectsCode(straddling, codeRanges: ranges))
    }

    @Test func proseRangeIsNeitherInsideNorTouchingCode() {
        let text = "run `git worktree add` first"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        let prose = range(of: "first", in: text)
        #expect(!ComposerCodeRanges.isEntirelyCode(prose, codeRanges: ranges))
        #expect(!ComposerCodeRanges.intersectsCode(prose, codeRanges: ranges))
    }

    @Test func emptyRangeAtACodeEdgeDoesNotCount() {
        let text = "run `git` first"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        let code = range(of: "`git`", in: text)
        #expect(!ComposerCodeRanges.intersectsCode(NSRange(location: code.location, length: 0), codeRanges: ranges))
        #expect(ComposerCodeRanges.intersectsCode(NSRange(location: code.location + 1, length: 0), codeRanges: ranges))
    }

    @Test func spellingResultsInCodeAreDropped() {
        let text = "teh `xcodebuild` runs"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
        let results = [
            NSTextCheckingResult.spellCheckingResult(range: range(of: "teh", in: text)),
            NSTextCheckingResult.spellCheckingResult(range: range(of: "xcodebuild", in: text)),
        ]
        let kept = ComposerCodeRanges.removingCodeResults(results, codeRanges: ranges)
        #expect(kept.map(\.range) == [range(of: "teh", in: text)])
    }

    @Test func nonSpellingResultsSurvive() {
        let text = "see `https://example.com` there"
        let ranges = ComposerCodeRanges.codeRanges(in: text)
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
