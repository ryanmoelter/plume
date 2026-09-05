import Foundation
import Testing
@testable import Plume

/// The language branch that sends a fence to the diagram renderer, and the
/// HTML template it builds.
struct MermaidDocumentTests {
    @Test func mermaidFenceIsRecognized() {
        let blocks = MarkdownBlock.parse("```mermaid\ngraph TD; A-->B;\n```")
        #expect(blocks == [.codeBlock(language: "mermaid", code: "graph TD; A-->B;")])
        guard case let .codeBlock(language, _) = blocks[0] else {
            Issue.record("expected a code block")
            return
        }
        #expect(MermaidDocument.isMermaidFence(language: language))
    }

    @Test func mermaidFenceIsCaseInsensitive() {
        #expect(MermaidDocument.isMermaidFence(language: "Mermaid"))
        #expect(MermaidDocument.isMermaidFence(language: "MERMAID"))
    }

    @Test func otherFencesStayCodeBlocks() {
        for language in ["swift", "bash", "json"] {
            let blocks = MarkdownBlock.parse("```\(language)\nbody\n```")
            #expect(blocks == [.codeBlock(language: language, code: "body")])
            #expect(!MermaidDocument.isMermaidFence(language: language))
        }
        #expect(!MermaidDocument.isMermaidFence(language: nil))
    }

    @Test func htmlCarriesSourceAndTheme() {
        let html = MermaidDocument.html(
            source: "graph TD; A-->B;",
            isDark: true,
            foregroundHex: "#ffffff"
        )
        #expect(html.contains("graph TD; A-->B;"))
        #expect(html.contains("theme: 'dark'"))
        #expect(html.contains("#ffffff"))
        #expect(html.contains("mermaid.min.js"))
        #expect(html.contains(MermaidDocument.messageHandlerName))
    }

    @Test func lightAppearanceUsesTheDefaultTheme() {
        let html = MermaidDocument.html(source: "graph TD;", isDark: false, foregroundHex: "#000000")
        #expect(html.contains("theme: 'default'"))
    }

    @Test func sourceIsEscapedAsAJavaScriptString() {
        // Quotes, backslashes and newlines would all end the literal early.
        let escaped = MermaidDocument.jsString("a \"b\" \\ c\nd")
        #expect(escaped.hasPrefix("\""))
        #expect(escaped.hasSuffix("\""))
        #expect(!escaped.contains("\n"))
        #expect(escaped.contains("\\\""))
        #expect(escaped.contains("\\n"))
    }

    @Test func closingScriptTagInSourceCannotEndTheBlock() {
        let html = MermaidDocument.html(
            source: "</script><script>alert(1)</script>",
            isDark: false,
            foregroundHex: "#000000"
        )
        #expect(!html.contains("<script>alert(1)"))
    }
}
