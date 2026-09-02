import SwiftUI

/// Which face chat prose renders in.
///
/// The bundled serif is for the agent's prose. The user's own messages and
/// the composer stay in the system face, so what you typed looks like input
/// rather than published text.
enum ChatProseFace {
    case serif
    case system
}

private struct ChatProseFaceKey: EnvironmentKey {
    static let defaultValue: ChatProseFace = .serif
}

extension EnvironmentValues {
    /// Set on the user's message rows; `MarkdownView` reads it to pick a face.
    var chatProseFace: ChatProseFace {
        get { self[ChatProseFaceKey.self] }
        set { self[ChatProseFaceKey.self] = newValue }
    }
}
