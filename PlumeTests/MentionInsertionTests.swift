import Foundation
import Testing
@testable import Plume

struct MentionInsertionTests {
    private let home = "/Users/tester"

    private func accept(
        _ candidate: MentionCandidate,
        in text: String,
        caret: Int? = nil
    ) throws -> SlashCommandMatcher.AcceptedCommand {
        let caret = caret ?? (text as NSString).length
        let query = try #require(MentionQuery.query(text: text, caretLocation: caret))
        return MentionInsertion.accepting(candidate, query: query, in: text)
    }

    private func file(_ path: String, isDirectory: Bool = false) -> MentionCandidate {
        .file(.init(path: path, isDirectory: isDirectory))
    }

    private let issue = MentionCandidate.linear(.init(
        identifier: "DROID-123",
        title: "Fix the text layout",
        url: "https://linear.app/acme/issue/DROID-123/fix-the-text-layout",
        stateType: .started,
        stateColor: "#f2c94c",
        updatedAt: Date(timeIntervalSince1970: 0)
    ))

    private let pull = MentionCandidate.pullRequest(.init(
        number: 123,
        title: "Add mentions",
        url: "https://github.com/o/r/pull/123",
        state: .open,
        isDraft: false,
        updatedAt: nil
    ))

    // MARK: - Formats

    @Test func aLinearIssueLeavesItsIdentifier() throws {
        #expect(try accept(issue, in: "see @dro layout").text == "see @DROID-123 ")
    }

    @Test func aPullRequestLeavesItsNumberFromEitherTrigger() throws {
        #expect(try accept(pull, in: "#12").text == "#123 ")
        #expect(try accept(pull, in: "@add").text == "#123 ")
    }

    @Test func aFileLeavesItsRelativePath() throws {
        let result = try accept(file("Plume/UI/Chat/ChatComposer.swift"), in: "@ChatCo")
        #expect(result.text == "@Plume/UI/Chat/ChatComposer.swift ")
    }

    @Test func aTypedHomePathKeepsItsTilde() throws {
        #expect(try accept(file("~/Development/notes.md"), in: "@~/Dev").text == "@~/Development/notes.md ")
        #expect(try accept(file("/etc/hosts"), in: "@/etc/ho").text == "@/etc/hosts ")
    }

    @Test func aPathThatWouldEndEarlyIsQuoted() throws {
        #expect(try accept(file("Docs/My Notes (draft).md"), in: "@notes").text == #"@"Docs/My Notes (draft).md" "#)
        #expect(try accept(file(#"a"b.txt"#), in: "@a").text == #"@"a\"b.txt" "#)
        #expect(try accept(file("DROID-12"), in: "@DRO").text == #"@"DROID-12" "#)
    }

    // MARK: - Drilling in

    @Test func aFolderLeavesItsPathWithASlashAndNoSpace() throws {
        let result = try accept(file("Plume/UI", isDirectory: true), in: "see @UI")
        #expect(result.text == "see @Plume/UI/")
        #expect(result.caretLocation == ("see @Plume/UI/" as NSString).length)
    }

    @Test func aQuotedFolderLeavesItsQuoteOpen() throws {
        let result = try accept(file("My Docs", isDirectory: true), in: "@My")
        #expect(result.text == #"@"My Docs/"#)
        let inside = try #require(MentionQuery.query(text: result.text, caretLocation: result.caretLocation))
        #expect(inside.text == "My Docs/")
        #expect(inside.isQuoted)
    }

    @Test func aFilterRowLeavesItsPrefix() throws {
        let result = try accept(.filter(.linear), in: "@li")
        #expect(result.text == "@linear:")
        #expect(result.caretLocation == 8)
    }

    @Test func theFilterPrefixGoesOnTheFinalAccept() throws {
        #expect(try accept(issue, in: "@linear:dro").text == "@DROID-123 ")
    }

    // MARK: - Links

    @Test func tildeExpansionToleratesATrailingSlashOnHome() {
        #expect(MentionInsertion.expandingTilde("~/a", homeDirectory: "/Users/tester/") == "/Users/tester/a")
        #expect(MentionInsertion.expandingTilde("~", homeDirectory: home) == home)
        #expect(MentionInsertion.expandingTilde("~other/a", homeDirectory: home) == "~other/a")
    }

    @Test func bracketsAndBackslashesInTheLabelAreEscaped() {
        #expect(MentionInsertion.escapedLabel(#"a[1]\b"#) == #"a\[1\]\\b"#)
    }

    @Test func aTargetWithSpacesOrParenthesesIsWrappedInAngleBrackets() {
        #expect(MentionInsertion.formattedTarget("a b.swift") == "<a b.swift>")
        #expect(MentionInsertion.formattedTarget("f(1).txt") == "<f(1).txt>")
        #expect(MentionInsertion.formattedTarget("plain/path.swift") == "plain/path.swift")
        #expect(MentionInsertion.formattedTarget("a <b>.txt") == #"<a \<b\>.txt>"#)
    }

    // MARK: - Replacement and caret

    @Test func theCaretLandsAfterTheTrailingSpace() throws {
        let result = try accept(pull, in: "fixes #12")
        #expect(result.caretLocation == (result.text as NSString).length)
    }

    @Test func theRestOfTheWordAfterTheCaretIsReplaced() throws {
        let result = try accept(file("ChatComposer.swift"), in: "@ChatComp and more", caret: 5)
        #expect(result.text == "@ChatComposer.swift and more")
        #expect(result.caretLocation == ("@ChatComposer.swift " as NSString).length)
    }

    @Test func anExistingSpaceAfterTheMentionIsNotDoubled() throws {
        #expect(try accept(pull, in: "#12 later", caret: 3).text == "#123 later")
    }

    @Test func closingPunctuationAfterTheCaretIsKept() throws {
        let parenthesized = try accept(file("Plume.swift"), in: "(see @Plum)", caret: 10)
        #expect(parenthesized.text == "(see @Plume.swift)")
        #expect(parenthesized.caretLocation == ("(see @Plume.swift" as NSString).length)

        #expect(try accept(file("Plume.swift"), in: "@Plum, then", caret: 5).text == "@Plume.swift, then")
    }

    @Test func aDotInsideTheWordIsReplacedButASentenceEndingOneIsKept() throws {
        #expect(try accept(file("Plume.swift"), in: "@Plum.sw later", caret: 5).text == "@Plume.swift later")
        #expect(try accept(file("Plume.swift"), in: "see @Plum.", caret: 9).text == "see @Plume.swift.")
    }

    @Test func caretOffsetsAreUTF16() throws {
        let result = try accept(pull, in: "🎉 #1")
        #expect(result.text == "🎉 #123 ")
        #expect(result.caretLocation == (result.text as NSString).length)
    }
}
