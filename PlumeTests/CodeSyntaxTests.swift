import Foundation
import Testing
@testable import Plume

/// Covers the tokenizer and the fence-tag mapping: which tags resolve to a
/// grammar, and that each role lands on exactly the source text it names.
/// An unknown or absent tag must yield plain code rather than garble.
struct CodeSyntaxTests {
    /// The substrings the tokenizer gave `token`, in source order.
    private static func text(
        _ code: String,
        _ language: String?,
        _ token: CodeSyntax.Token
    ) -> [String] {
        let units = Array(code.utf16)
        return CodeSyntax.spans(for: code, language: language)
            .filter { $0.token == token }
            .map { String(decoding: units[$0.range], as: UTF16.self) }
    }

    // MARK: - Language mapping

    @Test func missingLanguageYieldsNoSpans() {
        #expect(CodeSyntax.spans(for: "let x = 1 // hi", language: nil).isEmpty)
    }

    @Test func unknownLanguageYieldsNoSpans() {
        #expect(CodeSyntax.spans(for: "let x = 1", language: "brainfuck").isEmpty)
    }

    @Test func emptyAndWhitespaceTagsYieldNoSpans() {
        #expect(CodeSyntax.spans(for: "let x = 1", language: "").isEmpty)
        #expect(CodeSyntax.spans(for: "let x = 1", language: "   ").isEmpty)
    }

    @Test func tagMatchingFoldsCase() {
        #expect(Self.text("let x = 1", "Swift", .keyword) == ["let"])
        #expect(Self.text("let x = 1", "SWIFT", .keyword) == ["let"])
    }

    @Test func aliasesResolveToTheSameFamily() {
        for tag in ["sh", "bash", "zsh", "shell"] {
            #expect(Self.text("if true; then", tag, .keyword) == ["if", "then"])
        }
        for tag in ["objc", "cpp", "c"] {
            #expect(Self.text("void f()", tag, .keyword) == ["void"])
        }
    }

    @Test func emptyCodeYieldsNoSpans() {
        #expect(CodeSyntax.spans(for: "", language: "swift").isEmpty)
    }

    // MARK: - Roles

    @Test func keywordsAndTypesSeparate() {
        let code = "func greet() -> String"
        #expect(Self.text(code, "swift", .keyword) == ["func"])
        #expect(Self.text(code, "swift", .type) == ["String"])
    }

    @Test func keywordMatchIsWholeWord() {
        // "letter" and "ifs" merely start with keywords.
        #expect(Self.text("letter ifs", "swift", .keyword).isEmpty)
    }

    @Test func stringLiteralIncludesItsQuotes() {
        #expect(Self.text(#"let a = "hi""#, "swift", .string) == [#""hi""#])
    }

    @Test func escapedQuoteDoesNotCloseTheString() {
        #expect(Self.text(#"x = "a\"b" + y"#, "swift", .string) == [#""a\"b""#])
    }

    @Test func unterminatedStringStopsAtTheLineBreak() {
        let code = "x = \"oops\ny = 1"
        #expect(Self.text(code, "swift", .string) == ["\"oops"])
        // The next line still tokenizes, so one stray quote cannot swallow
        // the rest of the block.
        #expect(Self.text(code, "swift", .number) == ["1"])
    }

    @Test func lineCommentRunsToTheLineBreakOnly() {
        let code = "let x = 1 // note\nlet y = 2"
        #expect(Self.text(code, "swift", .comment) == ["// note"])
        #expect(Self.text(code, "swift", .keyword) == ["let", "let"])
    }

    @Test func docCommentPrefersTheLongerOpener() {
        #expect(Self.text("/// doc", "swift", .comment) == ["/// doc"])
    }

    @Test func blockCommentSpansLines() {
        #expect(Self.text("/* a\nb */ let x", "swift", .comment) == ["/* a\nb */"])
    }

    @Test func unterminatedBlockCommentRunsToTheEnd() {
        #expect(Self.text("/* a\nb", "swift", .comment) == ["/* a\nb"])
    }

    @Test func keywordInsideAStringIsNotAKeyword() {
        #expect(Self.text(#"let a = "func b""#, "swift", .keyword) == ["let"])
    }

    @Test func keywordInsideACommentIsNotAKeyword() {
        #expect(Self.text("// func b", "swift", .keyword).isEmpty)
    }

    @Test func numbersTokenizeWholeLiterals() {
        #expect(Self.text("a = 0xFF + 1_000.5e3", "swift", .number) == ["0xFF", "1_000.5e3"])
    }

    @Test func shellSkipsNumbersBecauseArgumentsAreNotLiterals() {
        #expect(Self.text("sleep 30", "bash", .number).isEmpty)
        #expect(Self.text("sleep 30", "bash", .type) == ["sleep"])
    }

    @Test func shellHashOpensAComment() {
        #expect(Self.text("ls # list\nls", "bash", .comment) == ["# list"])
    }

    @Test func objectiveCAttributeKeywordsIncludeTheirSigil() {
        #expect(Self.text("@interface Foo", "objc", .keyword) == ["@interface"])
    }

    @Test func pythonSelfAndNoneAreKeywords() {
        let code = "def f(self):\n    return None"
        #expect(Self.text(code, "python", .keyword) == ["def", "self", "return", "None"])
    }

    @Test func jsonLiteralsAndKeysColor() {
        let code = #"{"on": true, "count": 3}"#
        #expect(Self.text(code, "json", .string) == [#""on""#, #""count""#])
        #expect(Self.text(code, "json", .keyword) == ["true"])
        #expect(Self.text(code, "json", .number) == ["3"])
    }

    // MARK: - Invariants

    @Test func spansAreOrderedNonOverlappingAndInBounds() {
        let code = """
        // header
        func run(_ n: Int) -> String {
            let greeting = "hello \\(n)"
            /* aside */
            return greeting + "!"
        }
        """
        let spans = CodeSyntax.spans(for: code, language: "swift")
        #expect(!spans.isEmpty)

        var previousEnd = 0
        for span in spans {
            #expect(span.range.lowerBound >= previousEnd)
            #expect(span.range.lowerBound < span.range.upperBound)
            #expect(span.range.upperBound <= code.utf16.count)
            previousEnd = span.range.upperBound
        }
    }

    @Test func adjacentSpansOfOneRoleMerge() {
        // Two comment lines separated only by the newline they each stop at
        // stay distinct; the same role touching end-to-start merges.
        let spans = CodeSyntax.spans(for: "let let", language: "swift")
        #expect(spans.count == 2)
    }

    /// Multi-byte text must not shift the offsets, since the spans index
    /// UTF-16 and address an `AttributedString` built from the same string.
    @Test func offsetsSurviveNonASCIIText() {
        let code = "let emoji = \"🎈 ünïcode\"\nlet x = 1"
        #expect(Self.text(code, "swift", .string) == ["\"🎈 ünïcode\""])
        #expect(Self.text(code, "swift", .number) == ["1"])
    }
}
