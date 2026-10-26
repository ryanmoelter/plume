import Foundation
import Testing
@testable import Plume

struct MentionQueryTests {
    private func query(_ text: String, caret: Int? = nil) -> MentionQuery? {
        let caret = caret ?? (text as NSString).length
        return MentionQuery.query(
            text: text,
            caretLocation: caret,
            codeRanges: ComposerCodeRanges.codeRanges(in: text)
        )
    }

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
        #expect(query("#12")?.scope == .pullRequests)
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
        #expect(query("@~/Dev")?.scope == .files)
        #expect(query("@/Users")?.scope == .files)
        #expect(query("@./Plume")?.scope == .files)
        #expect(query("@UI/Chat")?.scope == .files)
        #expect(query("@Chat")?.scope == .all)
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
