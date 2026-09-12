import SwiftUI
import Testing
@testable import Plume

/// Covers the span-to-`AttributedString` walk: every token's color must land
/// on exactly its own characters, including past multi-byte text, and an
/// unhighlightable block must still come back as readable plain code.
@MainActor
struct CodeSyntaxPaletteTests {
    private static let palette = CodeSyntaxPalette(palette: Palette(colorScheme: .dark, definitions: nil))

    private static func color(
        _ code: String,
        _ language: String?,
        at offset: Int
    ) -> Color? {
        let attributed = AttributedString.highlightedCode(code, language: language, palette: palette)
        var index = attributed.startIndex
        var remaining = offset
        while remaining > 0, index < attributed.endIndex {
            remaining -= UTF16.width(attributed.unicodeScalars[index])
            index = attributed.unicodeScalars.index(after: index)
        }
        return attributed.runs[index].foregroundColor
    }

    @Test func keywordTakesTheKeywordColor() {
        #expect(Self.color("let x = 1", "swift", at: 0) == Self.palette.keyword)
    }

    @Test func unhighlightedTextTakesThePlainColor() {
        // The identifier between "let " and " =".
        #expect(Self.color("let x = 1", "swift", at: 4) == Self.palette.plain)
    }

    @Test func unknownLanguageRendersEntirelyPlain() {
        let attributed = AttributedString.highlightedCode("let x = 1", language: nil, palette: Self.palette)
        #expect(attributed.runs.allSatisfy { $0.foregroundColor == Self.palette.plain })
    }

    @Test func plainTextPreservesTheOriginalString() {
        let code = "anything at all\nsecond line"
        let attributed = AttributedString.highlightedCode(code, language: nil, palette: Self.palette)
        #expect(String(attributed.characters) == code)
    }

    @Test func highlightingPreservesTheOriginalString() {
        let code = "func f() { return \"x\" } // done"
        let attributed = AttributedString.highlightedCode(code, language: "swift", palette: Self.palette)
        #expect(String(attributed.characters) == code)
    }

    @Test func colorsLandCorrectlyAfterMultiByteText() {
        let code = "let s = \"🎈\"\nlet n = 1"
        // The second "let" sits past the emoji; a UTF-16 mismatch would shift
        // its color onto neighboring text.
        let offset = code.utf16.count - "let n = 1".utf16.count
        #expect(Self.color(code, "swift", at: offset) == Self.palette.keyword)
    }

    @Test func commentRecedesRatherThanTakingAHue() {
        #expect(Self.palette.comment != Self.palette.plain)
        #expect(Self.palette.comment != Self.palette.keyword)
    }

    @Test func cacheReturnsTheSameResultAsADirectHighlight() {
        let code = "let x = 1 // note"
        let cached = CodeSyntaxCache.highlighted(code, language: "swift", palette: Self.palette)
        let direct = AttributedString.highlightedCode(code, language: "swift", palette: Self.palette)
        #expect(cached == direct)
    }

    @Test func aVeryLongBlockFallsBackToPlainText() {
        let code = String(repeating: "let x = 1\n", count: 5_000)
        let highlighted = CodeSyntaxCache.highlighted(code, language: "swift", palette: Self.palette)
        #expect(String(highlighted.characters) == code)
        #expect(highlighted.runs.allSatisfy { $0.foregroundColor == Self.palette.plain })
    }
}
