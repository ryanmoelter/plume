import Foundation
import Testing
@testable import Plume

struct SlashCommandMatcherTests {
    private func command(_ name: String) -> SlashCommand {
        SlashCommand(name: name, description: "desc for \(name)", argumentHint: "")
    }

    @Test func emptyQueryReturnsAllCommandsAlphabetically() {
        let commands = [command("review"), command("clear"), command("model")]
        let result = SlashCommandMatcher.matches(query: "", in: commands)
        #expect(result.map(\.name) == ["clear", "model", "review"])
    }

    @Test func prefixMatchesRankAboveSubstringMatches() {
        let commands = [command("clear"), command("recycle"), command("cleanup")]
        let result = SlashCommandMatcher.matches(query: "cle", in: commands)
        // "clear" and "cleanup" are prefix matches (alphabetical); "recycle" only contains "cle".
        #expect(result.map(\.name) == ["cleanup", "clear", "recycle"])
    }

    @Test func queryIsCaseInsensitive() {
        let commands = [command("Model")]
        let result = SlashCommandMatcher.matches(query: "MOD", in: commands)
        #expect(result.map(\.name) == ["Model"])
    }

    @Test func noMatchReturnsEmpty() {
        let commands = [command("clear"), command("model")]
        let result = SlashCommandMatcher.matches(query: "zzz", in: commands)
        #expect(result.isEmpty)
    }

    @Test func queryExtractsTokenAfterSlash() {
        let query = SlashCommandMatcher.query(text: "/mod", caretLocation: 4)
        #expect(query == "mod")
    }

    @Test func queryIsEmptyStringRightAfterSlash() {
        let query = SlashCommandMatcher.query(text: "/", caretLocation: 1)
        #expect(query == "")
    }

    @Test func queryIsNilWithoutLeadingSlash() {
        let query = SlashCommandMatcher.query(text: "hello /model", caretLocation: 12)
        #expect(query == nil)
    }

    @Test func queryIsNilOnceCaretLeavesFirstToken() {
        let query = SlashCommandMatcher.query(text: "/model arg", caretLocation: 10)
        #expect(query == nil)
    }

    @Test func queryIsValidAtBoundaryBeforeWhitespace() {
        let query = SlashCommandMatcher.query(text: "/model arg", caretLocation: 6)
        #expect(query == "model")
    }

    @Test func queryIsNilWhenCaretPrecedesSlash() {
        let query = SlashCommandMatcher.query(text: "/model", caretLocation: 0)
        #expect(query == nil)
    }

    @Test func queryHandlesNewlineAsTokenBoundary() {
        let query = SlashCommandMatcher.query(text: "/model\nmore text", caretLocation: 6)
        #expect(query == "model")
    }

    @Test func recognizedCommandRangeMatchesExactLeadingToken() {
        let range = SlashCommandMatcher.recognizedCommandRange(text: "/model", commandNames: ["model", "clear"])
        #expect(range == NSRange(location: 0, length: 6))
    }

    @Test func recognizedCommandRangeCoversTokenOnlyWithTrailingArgs() {
        let range = SlashCommandMatcher.recognizedCommandRange(text: "/model opus", commandNames: ["model"])
        #expect(range == NSRange(location: 0, length: 6))
    }

    @Test func recognizedCommandRangeIsNilForUnknownCommand() {
        let range = SlashCommandMatcher.recognizedCommandRange(text: "/bogus", commandNames: ["model", "clear"])
        #expect(range == nil)
    }

    @Test func recognizedCommandRangeIsNilWithoutLeadingSlash() {
        let range = SlashCommandMatcher.recognizedCommandRange(text: "model", commandNames: ["model"])
        #expect(range == nil)
    }

    @Test func recognizedCommandRangeIsNilForBareSlash() {
        let range = SlashCommandMatcher.recognizedCommandRange(text: "/", commandNames: ["model"])
        #expect(range == nil)
    }

    @Test func recognizedCommandRangeRequiresExactMatchNotPrefix() {
        let range = SlashCommandMatcher.recognizedCommandRange(text: "/mod", commandNames: ["model"])
        #expect(range == nil)
    }

    @Test func acceptingReplacesLeadingTokenAndPlacesCaretAfterIt() {
        let accepted = SlashCommandMatcher.accepting(command("model"), in: "/mod")
        #expect(accepted.text == "/model ")
        #expect(accepted.caretLocation == 7)
    }

    @Test func acceptingPreservesTrailingArguments() {
        let accepted = SlashCommandMatcher.accepting(command("model"), in: "/mod opus-4")
        #expect(accepted.text == "/model  opus-4")
        #expect(accepted.caretLocation == "/model ".utf16.count)
    }
}
