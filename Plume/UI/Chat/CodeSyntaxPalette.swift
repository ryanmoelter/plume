import SwiftUI

/// The color each syntax role draws in, taken from the terminal theme.
///
/// Roles map onto the same ANSI slots `Palette` already draws status accents
/// from, which is what keeps a highlighted block reading as part of the same
/// surface as the terminal beside it. A theme that supplies no palette falls
/// through to `Palette`'s own system-color fallbacks, so light and dark both
/// work without a hardcoded scheme.
struct CodeSyntaxPalette {
    let keyword: Color
    let string: Color
    let comment: Color
    let number: Color
    let type: Color
    let plain: Color

    init(palette: Palette) {
        keyword = palette.warning
        string = palette.success
        number = palette.danger
        type = palette.attention
        plain = palette.foreground
        // Comments recede rather than take a hue: they are the one role the
        // reader is meant to skip.
        comment = palette.foreground.opacity(palette.emphasis[.disabled])
    }

    func color(for token: CodeSyntax.Token) -> Color {
        switch token {
        case .plain: plain
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .type: type
        }
    }
}

extension AttributedString {
    /// `code` with each token colored, or plain text when the language is
    /// unknown, absent, or has nothing to mark.
    static func highlightedCode(
        _ code: String,
        language: String?,
        palette: CodeSyntaxPalette
    ) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = palette.plain

        let spans = CodeSyntax.spans(for: code, language: language)
        guard !spans.isEmpty else { return attributed }

        // One walk for all spans: the offsets arrive in source order, so the
        // cursor only ever moves forward. Resolving each independently would
        // be quadratic in the number of tokens.
        var cursor = Cursor(attributed)
        for span in spans {
            guard
                let lower = cursor.advance(to: span.range.lowerBound),
                let upper = cursor.advance(to: span.range.upperBound)
            else { break }
            attributed[lower ..< upper].foregroundColor = palette.color(for: span.token)
        }
        return attributed
    }
}

/// Walks an `AttributedString`'s unicode scalars, translating the tokenizer's
/// UTF-16 offsets into indices.
private struct Cursor {
    private let scalars: AttributedString.UnicodeScalarView
    private var index: AttributedString.Index
    private var offset = 0

    init(_ attributed: AttributedString) {
        scalars = attributed.unicodeScalars
        index = scalars.startIndex
    }

    /// The index at `target`, or nil once the walk runs off the end.
    mutating func advance(to target: Int) -> AttributedString.Index? {
        while offset < target, index < scalars.endIndex {
            offset += UTF16.width(scalars[index])
            index = scalars.index(after: index)
        }
        return offset == target ? index : nil
    }
}
