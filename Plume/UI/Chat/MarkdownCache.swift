import Foundation
import SwiftUI

/// Memoizes the two markdown conversions that sit on the scroll path.
///
/// `MarkdownView` re-runs on every `body` pass, and SwiftUI evaluates `body`
/// constantly while scrolling. Both `MarkdownBlock.parse` and
/// `AttributedString(markdown:)` are pure functions of their input string, so
/// the result can be reused instead of recomputed — inline parsing alone
/// measured 0.083ms per block, which a screenful of blocks turns into more
/// than a frame's budget.
///
/// Bounded because a long-running session would otherwise hold every string
/// it has ever rendered. Eviction is crude on purpose: this is a render
/// cache, and a miss only costs what the work cost before.
@MainActor
enum MarkdownCache {
    /// Comfortably more than one screenful of either kind, small enough that
    /// the memory never matters.
    private static let limit = 512

    private static var blockCache: [String: [MarkdownBlock]] = [:]
    private static var inlineCache: [String: AttributedString] = [:]

    static func blocks(for markdown: String) -> [MarkdownBlock] {
        if let cached = blockCache[markdown] { return cached }
        let parsed = MarkdownBlock.parse(markdown)
        if blockCache.count >= limit { blockCache.removeAll(keepingCapacity: true) }
        blockCache[markdown] = parsed
        return parsed
    }

    /// Inline-only parsing (bold, italic, inline code, links) that keeps
    /// single newlines inside the block rather than collapsing them.
    static func inline(_ text: String) -> AttributedString {
        if let cached = inlineCache[text] { return cached }
        let parsed = (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
        if inlineCache.count >= limit { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[text] = parsed
        return parsed
    }

    /// Drops everything. For tests.
    static func reset() {
        blockCache.removeAll()
        inlineCache.removeAll()
    }
}
