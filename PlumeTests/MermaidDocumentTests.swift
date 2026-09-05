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

    @Test func bothSizingModesCenterTheDiagram() {
        for sizing in [MermaidDocument.Sizing.natural, .fit] {
            let html = MermaidDocument.html(
                source: "graph TD;",
                isDark: false,
                foregroundHex: "#000000",
                sizing: sizing
            )
            #expect(html.contains("justify-content: center"))
            #expect(html.contains("margin: 0 auto"))
        }
    }

    @Test func naturalSizingLetsTheDiagramKeepItsHeight() {
        let html = MermaidDocument.html(source: "graph TD;", isDark: false, foregroundHex: "#000000")
        #expect(html.contains("height: auto"))
        // Capping the height here would stop the reported height being the
        // diagram's own, which is what the row's frame is taken from.
        #expect(!html.contains("max-height"))
        // The page still cannot scroll; only its height is uncapped.
        #expect(html.contains("overflow: hidden"))
    }

    @Test func fitSizingScalesTheDiagramToTheViewport() {
        let html = MermaidDocument.html(
            source: "graph TD;",
            isDark: false,
            foregroundHex: "#000000",
            sizing: .fit
        )
        #expect(html.contains("max-height: 100%"))
        #expect(html.contains("align-items: center"))
        #expect(html.contains("height: 100%"))
    }

    @Test func neitherSizingModeLetsThePageScroll() {
        // A page with something to scroll swallows the wheel event that
        // should reach the chat list.
        for sizing in [MermaidDocument.Sizing.natural, .fit] {
            let html = MermaidDocument.html(
                source: "graph TD; A-->B;",
                isDark: false,
                foregroundHex: "#000000",
                sizing: sizing
            )
            #expect(html.contains("overflow: hidden"))
            #expect(html.contains("overscroll-behavior: none"))
            #expect(!html.contains("-webkit-overflow-scrolling: touch"))
        }
    }

    @Test func renderReportCarriesTheContainerSize() {
        let html = MermaidDocument.html(
            source: "graph TD;",
            isDark: false,
            foregroundHex: "#000000",
            sizing: .fit
        )
        #expect(html.contains("viewportWidth"))
        #expect(html.contains("viewportHeight"))
        // A container sized after the first layout still reports once it is.
        #expect(html.contains("addEventListener('resize'"))
    }

    @Test func bothSizingModesStillReportAndCarryTheSource() {
        for sizing in [MermaidDocument.Sizing.natural, .fit] {
            let html = MermaidDocument.html(
                source: "graph TD; A-->B;",
                isDark: true,
                foregroundHex: "#ffffff",
                sizing: sizing
            )
            #expect(html.contains("graph TD; A-->B;"))
            #expect(html.contains("kind: 'rendered'"))
            #expect(html.contains(MermaidDocument.messageHandlerName))
            #expect(html.contains("theme: 'dark'"))
        }
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
