import Foundation
import SwiftUI

/// Memoizes highlighted code, for the same reason `MarkdownCache` memoizes
/// parsing: `body` re-runs constantly while scrolling, and tokenizing a long
/// block on each pass would scale render cost with code length.
///
/// Bounded and evicted crudely — a miss only costs what the work cost before.
@MainActor
enum CodeSyntaxCache {
    private static let limit = 256

    /// Blocks longer than this render plain. Past a few hundred lines the
    /// reader is scrolling a dump rather than reading code, and the tokenize
    /// would be the most expensive thing on the scroll path.
    private static let maxHighlightedLength = 20_000

    /// The palette and font size key the cache alongside the code: a
    /// light/dark switch has to miss rather than return the old appearance.
    private struct Key: Hashable {
        let code: String
        let language: String?
        let keyword: Color
        let plain: Color
    }

    private static var cache: [Key: AttributedString] = [:]

    static func highlighted(
        _ code: String,
        language: String?,
        palette: CodeSyntaxPalette
    ) -> AttributedString {
        guard code.utf16.count <= maxHighlightedLength else {
            var plain = AttributedString(code)
            plain.foregroundColor = palette.plain
            return plain
        }

        let key = Key(code: code, language: language, keyword: palette.keyword, plain: palette.plain)
        if let cached = cache[key] { return cached }

        let highlighted = AttributedString.highlightedCode(code, language: language, palette: palette)
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[key] = highlighted
        return highlighted
    }
}
