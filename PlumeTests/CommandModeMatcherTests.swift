import Foundation
import Testing
@testable import Plume

struct CommandModeMatcherTests {
    @Test func aLeadingBangEntersCommandModeWithoutItself() {
        #expect(CommandModeMatcher.enteringCommandMode("!") == "")
        #expect(CommandModeMatcher.enteringCommandMode("!ls -la") == "ls -la")
    }

    /// Pasting a whole command enters the mode the same way typing one does.
    @Test func aPastedCommandEntersCommandModeToo() {
        #expect(CommandModeMatcher.enteringCommandMode("!git status --short") == "git status --short")
    }

    @Test func aBangLaterInTheMessageIsNotACommand() {
        #expect(CommandModeMatcher.enteringCommandMode("run this! please") == nil)
    }

    @Test func anEscapedBangIsNotACommand() {
        #expect(CommandModeMatcher.enteringCommandMode("\\!not a command") == nil)
    }

    @Test func unescapingStripsTheBackslashFromAnEscapedBang() {
        #expect(CommandModeMatcher.unescaped("\\!not a command") == "!not a command")
    }

    @Test func unescapingLeavesOrdinaryProseAlone() {
        #expect(CommandModeMatcher.unescaped("just a message") == "just a message")
    }

    /// The composer stays in command mode with an empty draft, which has
    /// nothing to run — sending then does nothing rather than running a blank
    /// line.
    @Test func anEmptyDraftHasNothingToRun() {
        #expect(CommandModeMatcher.parse("") == nil)
        #expect(CommandModeMatcher.parse("   ") == nil)
    }

    @Test func commandIsTrimmed() {
        #expect(CommandModeMatcher.parse("  ls  ") == "ls")
    }

    @Test func multilineCommandKeepsItsLaterLines() {
        #expect(CommandModeMatcher.parse("echo one\necho two") == "echo one\necho two")
    }
}
