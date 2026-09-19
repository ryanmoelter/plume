import Foundation
import Testing
@testable import Plume

struct CommandModeMatcherTests {
    @Test func recognizesALeadingBang() {
        #expect(CommandModeMatcher.parse("!ls -la") == "ls -la")
    }

    @Test func commandRangeCoversTheWholeMessage() {
        let text = "!git status"
        #expect(CommandModeMatcher.commandRange(text: text) == NSRange(location: 0, length: 11))
    }

    @Test func markerRangeCoversOnlyTheBang() {
        #expect(CommandModeMatcher.markerRange(text: "!git status") == NSRange(location: 0, length: 1))
    }

    @Test func aBareBangHasNothingToRun() {
        #expect(CommandModeMatcher.parse("!") == nil)
        #expect(CommandModeMatcher.parse("!   ") == nil)
    }

    /// The `!` styles the moment it is typed, before any command follows it,
    /// so the keystroke that enters the mode is acknowledged.
    @Test func aBareBangStylesAsCommandMode() {
        #expect(CommandModeMatcher.commandRange(text: "!") == NSRange(location: 0, length: 1))
        #expect(CommandModeMatcher.markerRange(text: "!") == NSRange(location: 0, length: 1))
        #expect(CommandModeMatcher.commandRange(text: "!   ") != nil)
    }

    @Test func aBangLaterInTheMessageIsNotACommand() {
        #expect(CommandModeMatcher.parse("run this! please") == nil)
        #expect(CommandModeMatcher.commandRange(text: "run this! please") == nil)
    }

    @Test func anEscapedBangIsNotACommand() {
        #expect(CommandModeMatcher.parse("\\!not a command") == nil)
    }

    @Test func unescapingStripsTheBackslashFromAnEscapedBang() {
        #expect(CommandModeMatcher.unescaped("\\!not a command") == "!not a command")
    }

    @Test func unescapingLeavesOrdinaryProseAlone() {
        #expect(CommandModeMatcher.unescaped("just a message") == "just a message")
    }

    /// The styler paints the two ranges together, so a disagreement would
    /// leave a red marker on a message that is not in command mode.
    @Test func bothRangesAgreeOnWhetherTextIsACommand() {
        for text in ["!ls", "!", "!  ", "hello", "", "\\!escaped", "a!b", "!\nx"] {
            #expect(
                (CommandModeMatcher.commandRange(text: text) == nil)
                    == (CommandModeMatcher.markerRange(text: text) == nil),
                "disagreed on \(text)"
            )
        }
    }

    @Test func commandIsTrimmed() {
        #expect(CommandModeMatcher.parse("!  ls  ") == "ls")
    }

    @Test func multilineCommandKeepsItsLaterLines() {
        #expect(CommandModeMatcher.parse("!echo one\necho two") == "echo one\necho two")
    }
}
