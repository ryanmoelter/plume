import Foundation
import Testing
@testable import Plume

struct MentionQueryTests {
    private func query(_ text: String, caret: Int? = nil) -> MentionQuery? {
        let caret = caret ?? (text as NSString).length
        return MentionQuery.query(text: text, caretLocation: caret)
    }

    private let everySource: Set<MentionCandidate.Source> = [.linear, .pullRequests, .files]

    // MARK: - Opening

    @Test func anAtSignAtTheStartOpens() {
        let result = query("@cha")
        #expect(result?.trigger == .at)
        #expect(result?.text == "cha")
        #expect(result?.range == NSRange(location: 0, length: 4))
    }

    @Test func aBareTriggerOpensWithAnEmptyQuery() {
        #expect(query("see @")?.text == "")
        #expect(query("#")?.text == "")
    }

    @Test func aTriggerAfterWhitespaceOrOpeningPunctuationOpens() {
        #expect(query("look at @foo")?.text == "foo")
        #expect(query("(@foo")?.text == "foo")
        #expect(query("[@foo")?.text == "foo")
        #expect(query("\"@foo")?.text == "foo")
        #expect(query("'@foo")?.text == "foo")
        #expect(query("a\tb @foo")?.text == "foo")
    }

    @Test func aTriggerInsideAWordDoesNotOpen() {
        #expect(query("a@b") == nil)
        #expect(query("me@example.com") == nil)
        #expect(query("C#") == nil)
        #expect(query("issue#12") == nil)
    }

    @Test func theHashTriggerSearchesOnlyPullRequests() {
        #expect(query("#12")?.sources == [.pullRequests])
    }

    @Test func theQueryRunsOnlyToTheCaret() {
        let result = query("@ChatComposer", caret: 5)
        #expect(result?.text == "Chat")
        #expect(result?.caretLocation == 5)
    }

    @Test func theCaretBeforeTheTriggerOpensNothing() {
        #expect(query("@foo", caret: 0) == nil)
    }

    @Test func theQueryStaysOnTheCaretsLine() {
        #expect(query("@foo\nbar") == nil)
        #expect(query("first line\n@bar")?.text == "bar")
        #expect(query("first line\n@bar")?.triggerLocation == 11)
    }

    @Test func theNearestTriggerWins() {
        let result = query("@one and @two")
        #expect(result?.text == "two")
        #expect(result?.triggerLocation == 9)
    }

    @Test func aTriggerInCodeDoesNotOpen() {
        #expect(query("`see @foo` now", caret: 9) == nil)
        #expect(query("`see @foo") != nil, "an unterminated backtick is not code")
        #expect(query("```\n@foo") == nil)
    }

    @Test func aTriggerInsideAnExistingLinkDoesNotOpen() {
        let text = "[@foo](https://x.dev) after"
        #expect(query(text, caret: 5) == nil)
    }

    @Test func aQuerySpanningALinkDoesNotOpen() {
        #expect(query("ping @sam about [ChatComposer.swift](Plume/UI/Chat/ChatComposer.swift) ") == nil)
        #expect(query("ping @sam `x` ") == nil)
    }

    @Test func multiWordQueriesStayOpen() {
        #expect(query("@dro layout")?.text == "dro layout")
        #expect(query("@dro ")?.text == "dro ")
        #expect(query("@one two three four five")?.text == "one two three four five")
    }

    // MARK: - Closing

    @Test func aSpaceRightAfterTheTriggerCloses() {
        #expect(query("meet @ 5pm") == nil)
        #expect(query("# Heading") == nil)
    }

    @Test func twoSpacesInARowClose() {
        #expect(query("@dro  layout") == nil)
        #expect(query("@dro  ") == nil)
    }

    @Test func moreThanFiveWordsClose() {
        #expect(query("@one two three four five six") == nil)
    }

    @Test func aDoubleHashCloses() {
        #expect(query("##") == nil)
        #expect(query("## Heading") == nil)
    }

    @Test func aSpaceIsReportedForTheNoResultsRule() {
        #expect(query("@dro layout")?.containsSpace == true)
        #expect(query("@dro")?.containsSpace == false)
    }

    // MARK: - Path shapes

    @Test func pathShapedQueriesSearchOnlyFiles() {
        #expect(query("@~/Dev")?.sources == [.files])
        #expect(query("@/Users")?.sources == [.files])
        #expect(query("@./Plume")?.sources == [.files])
        #expect(query("@UI/Chat")?.sources == [.files])
        #expect(query("@Chat")?.sources == everySource)
    }

    @Test func aQuotedPathSearchesFilesWithoutItsQuote() {
        let result = query("see @\"My No")
        #expect(result?.isQuoted == true)
        #expect(result?.text == "My No")
        #expect(result?.sources == [.files])
    }

    @Test func aClosedQuoteIsAReferenceNotAQuery() {
        #expect(query("@\"My Notes.md\" and") == nil)
    }

    @Test func aTriggerInsideAnOpenQuotedPathIsPartOfThePath() {
        let result = query("@\"Notes #2")
        #expect(result?.triggerLocation == 0)
        #expect(result?.text == "Notes #2")
    }

    // MARK: - Complete references

    @Test func proseAfterACompleteReferenceCloses() {
        #expect(query("@DROID-123 ") == nil)
        #expect(query("see @DROID-123 and more") == nil)
        #expect(query("#12 fixes it") == nil)
        #expect(query("@Plume/UI/Chat.swift is it") == nil)
        #expect(query("@DROID-123")?.text == "DROID-123")
        #expect(query("@droid- layout")?.text == "droid- layout")
    }

    // MARK: - Filters

    @Test func aFilterPrefixKeepsTheMenuToOneSource() {
        let linear = query("@linear:dro layout")
        #expect(linear?.filter == .linear)
        #expect(linear?.text == "dro layout")
        #expect(linear?.sources == [.linear])
        #expect(query("@pr:12")?.sources == [.pullRequests])
        #expect(query("@file:src/a")?.sources == [.files])
        #expect(query("@File:x")?.filter == .file)
        #expect(query("#pr:1")?.filter == nil)
    }

    @Test func aFilterPrefixWithNothingAfterItIsNotBare() {
        #expect(query("@linear:")?.text == "")
        #expect(query("@linear:")?.isBare == false)
        #expect(query("@")?.isBare == true)
    }

    @Test func twoLettersStartingAFilterSuggestIt() {
        #expect(query("@li")?.suggestedFilters == [.linear])
        #expect(query("@pr")?.suggestedFilters == [.pr])
        #expect(query("@FI")?.suggestedFilters == [.file])
        #expect(query("@linear")?.suggestedFilters == [.linear])
        #expect(query("@l")?.suggestedFilters == [])
        #expect(query("@lix")?.suggestedFilters == [])
        #expect(query("@linear:x")?.suggestedFilters == [])
        #expect(query("#pr")?.suggestedFilters == [])
    }

    // MARK: - Markup

    @Test func onlyTheCaretsLineIsParsedWithoutAFence() {
        let text = "`code @x`\nsee [a](b) @foo"
        let markup = MentionMarkup.around((text as NSString).length, in: text)
        #expect(markup.codeRanges.isEmpty)
        #expect(markup.linkRanges == [NSRange(location: 14, length: 6)])
    }

    @Test func aFenceEarlierInTheTextStillHidesTheCaretsLine() {
        #expect(query("intro\n```\ncode\n@foo") == nil)
        #expect(query("```\ncode\n```\n@foo")?.text == "foo")
    }

    @Test func homeAndRootQueriesAreAbsolute() {
        #expect(query("@~/Dev")?.isAbsolutePath == true)
        #expect(query("@~")?.isAbsolutePath == true)
        #expect(query("@/Users")?.isAbsolutePath == true)
        #expect(query("@./Plume")?.isAbsolutePath == false)
        #expect(query("@UI/Chat")?.isAbsolutePath == false)
    }

    @Test func offsetsAreUTF16() {
        let result = query("🎉 @foo")
        #expect(result?.triggerLocation == 3)
        #expect(result?.text == "foo")
    }
}
