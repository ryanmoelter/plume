import Foundation

/// Which container draws the chat list. Both take the same pieces.
nonisolated enum ChatListEngine: String, CaseIterable {
    /// SwiftUI's `LazyVStack`, with the 300 pt ceiling `docs/chat-list-hang.md`
    /// explains.
    case lazyStack
    /// Plume's own `NSScrollView` list. See `docs/chat-list.md`.
    case custom

    /// `PLUME_CHAT_LIST_ENGINE=custom|lazy` wins over the setting, so the
    /// harness can pick an engine without touching defaults.
    static var environmentOverride: ChatListEngine? {
        switch ProcessInfo.processInfo.environment["PLUME_CHAT_LIST_ENGINE"] {
        case "custom": .custom
        case "lazy", "lazyStack": .lazyStack
        default: nil
        }
    }
}
