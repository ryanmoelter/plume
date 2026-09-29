import Foundation

/// When a composer holds something worth sending.
///
/// Reads the visible text, never the markdown: an empty heading or list item
/// serializes to non-empty scaffolding with nothing on screen. In command mode
/// the visible text is the command itself, so the same rule covers it.
nonisolated enum ComposerSendability {
    static func hasText(_ visibleText: String) -> Bool {
        visibleText.contains { !$0.isWhitespace }
    }

    /// An image alone is a message worth sending.
    static func canSend(hasText: Bool, hasAttachments: Bool) -> Bool {
        hasText || hasAttachments
    }
}
