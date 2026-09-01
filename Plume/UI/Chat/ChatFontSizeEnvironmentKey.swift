import SwiftUI

private struct ChatFontSizeKey: EnvironmentKey {
    // MarkdownView is also used outside the chat, so an absent environment
    // value must still fall back to AppSettings' default rather than 0.
    static let defaultValue: CGFloat = CGFloat(AppSettings.defaultChatFontSize)
}

extension EnvironmentValues {
    /// Point size for chat prose. Set once by `ChatTabView`; `MarkdownView`
    /// and its sibling chat rows read it to scale together.
    var chatFontSize: CGFloat {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
}
