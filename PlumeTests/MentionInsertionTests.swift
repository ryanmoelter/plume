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
        let query = try #require(MentionQuery.query(text: text, caretLocation: caret, codeRanges: []))
        return MentionInsertion.accepting(candidate, query: query, in: text, homeDirectory: home)
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

    @Test func aLinearIssueLinksItsIdentifierToItsURL() throws {
        let result = try accept(issue, in: "see @dro layout")
        #expect(result.text == "see [DROID-123](https://linear.app/acme/issue/DROID-123/fix-the-text-layout) ")
    }

    @Test func aPullRequestLinksItsNumber() throws {
        let result = try accept(pull, in: "#12")
        #expect(result.text == "[#123](https://github.com/o/r/pull/123) ")
    }

    @Test func aFileLinksItsNameToItsRelativePath() throws {
        let result = try accept(file("Plume/UI/Chat/ChatComposer.swift"), in: "@ChatCo")
        #expect(result.text == "[ChatComposer.swift](Plume/UI/Chat/ChatComposer.swift) ")
    }

    @Test func aFolderLabelEndsInASlash() throws {
        let result = try accept(file("Plume/UI", isDirectory: true), in: "@UI")
        #expect(result.text == "[UI/](Plume/UI) ")
    }

    @Test func aHomePathIsExpanded() throws {
        let result = try accept(file("~/Development/Plume", isDirectory: true), in: "@~/Dev")
        #expect(result.text == "[Plume/](/Users/tester/Development/Plume) ")
    }

    @Test func anAbsolutePathStaysAsIs() throws {
        let result = try accept(file("/etc/hosts"), in: "@/etc/ho")
        #expect(result.text == "[hosts](/etc/hosts) ")
    }

    @Test func tildeExpansionToleratesATrailingSlashOnHome() {
        #expect(MentionInsertion.expandingTilde("~/a", homeDirectory: "/Users/tester/") == "/Users/tester/a")
        #expect(MentionInsertion.expandingTilde("~", homeDirectory: home) == home)
        #expect(MentionInsertion.expandingTilde("~other/a", homeDirectory: home) == "~other/a")
    }

    // MARK: - Escaping

    @Test func bracketsAndBackslashesInTheLabelAreEscaped() {
        #expect(MentionInsertion.escapedLabel(#"a[1]\b"#) == #"a\[1\]\\b"#)
    }

    @Test func aTargetWithSpacesOrParenthesesIsWrappedInAngleBrackets() {
        #expect(MentionInsertion.formattedTarget("a b.swift") == "<a b.swift>")
        #expect(MentionInsertion.formattedTarget("f(1).txt") == "<f(1).txt>")
        #expect(MentionInsertion.formattedTarget("plain/path.swift") == "plain/path.swift")
        #expect(MentionInsertion.formattedTarget("a <b>.txt") == #"<a \<b\>.txt>"#)
    }

    @Test func aFileWithSpacesProducesAParseableLink() throws {
        let result = try accept(file("Docs/My Notes (draft).md"), in: "@notes")
        #expect(result.text == "[My Notes (draft).md](<Docs/My Notes (draft).md>) ")
        let parsed = try AttributedString(markdown: result.text)
        #expect(parsed.runs.contains { $0.link != nil })
    }

    // MARK: - Replacement and caret

    @Test func theCaretLandsAfterTheTrailingSpace() throws {
        let result = try accept(pull, in: "fixes #12")
        #expect(result.caretLocation == (result.text as NSString).length)
    }

    @Test func theRestOfTheWordAfterTheCaretIsReplaced() throws {
        let text = "@ChatComp and more"
        let result = try accept(file("ChatComposer.swift"), in: text, caret: 5)
        #expect(result.text == "[ChatComposer.swift](ChatComposer.swift) and more")
        #expect(result.caretLocation == ("[ChatComposer.swift](ChatComposer.swift) " as NSString).length)
    }

    @Test func textAfterTheMentionIsKept() throws {
        let text = "see @dro and then"
        let result = try accept(issue, in: text, caret: 8)
        #expect(result.text.hasPrefix("see [DROID-123]("))
        #expect(result.text.hasSuffix(") and then"))
    }

    @Test func anExistingSpaceAfterTheMentionIsNotDoubled() throws {
        let result = try accept(pull, in: "#12 later", caret: 3)
        #expect(result.text == "[#123](https://github.com/o/r/pull/123) later")
    }

    @Test func closingPunctuationAfterTheCaretIsKept() throws {
        let link = "[Plume.swift](Plume.swift)"
        let parenthesized = try accept(file("Plume.swift"), in: "(see @Plum)", caret: 10)
        #expect(parenthesized.text == "(see \(link))")
        #expect(parenthesized.caretLocation == ("(see \(link)" as NSString).length)

        let comma = try accept(file("Plume.swift"), in: "@Plum, then", caret: 5)
        #expect(comma.text == "\(link), then")
    }

    @Test func aDotInsideTheWordIsReplacedButASentenceEndingOneIsKept() throws {
        let link = "[Plume.swift](Plume.swift)"
        #expect(try accept(file("Plume.swift"), in: "@Plum.sw later", caret: 5).text == "\(link) later")
        #expect(try accept(file("Plume.swift"), in: "see @Plum.", caret: 9).text == "see \(link).")
    }

    @Test func caretOffsetsAreUTF16() throws {
        let result = try accept(pull, in: "🎉 #1")
        #expect(result.text == "🎉 [#123](https://github.com/o/r/pull/123) ")
        #expect(result.caretLocation == (result.text as NSString).length)
    }
}
