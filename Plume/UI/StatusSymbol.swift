import Foundation

/// The one place a concept is paired with a symbol, so the sidebar, the chat,
/// the minimap and the subagent list cannot drift apart.
///
/// Each concept names one symbol family. `filled` is for a status badge, where
/// the symbol carries the whole meaning at a glance; the plain form is for an
/// inline marker beside text that already says what it is. Never mix families
/// for one concept — a question is a bubble everywhere, not a bubble in the
/// chat and a circle in the sidebar.
enum StatusSymbol: CaseIterable {
    case question
    case plan
    case permission
    case interruption
    case terminalInput
    case done
    case error
    case awaitingReply
    /// A session someone can drive from elsewhere.
    case remoteControl

    var name: String {
        switch self {
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .permission: "hand.raised"
        // Distinct from `permission`: a raised hand asks to go on, a crossed
        // out one says the work stopped.
        case .interruption: "hand.raised.slash"
        case .terminalInput: "bell"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        case .awaitingReply: "arrow.uturn.backward"
        case .remoteControl: "antenna.radiowaves.left.and.right"
        }
    }

    /// The filled variant, for a status badge that stands alone.
    ///
    /// Not every symbol has one — `arrow.uturn.backward` and the antenna are
    /// strokes with nothing to fill — and naming a symbol that does not exist
    /// draws nothing at all, so those stand as themselves. `StatusSymbolTests`
    /// is what keeps this list honest.
    var filled: String {
        switch self {
        case .awaitingReply, .remoteControl: name
        default: "\(name).fill"
        }
    }
}
