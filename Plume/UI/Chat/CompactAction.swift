import Foundation

/// The context popover's Compact button. It sends `/compact` the way the
/// composer sends any message, so it never races a running turn: the button
/// stays disabled instead of queueing the command behind it.
struct CompactAction {
    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    let availability: Availability
    let run: () -> Void

    static let command = "/compact"

    static func availability(isWorking: Bool, isRestarting: Bool, hasConversation: Bool) -> Availability {
        if !hasConversation { return .unavailable(reason: "Nothing to compact yet") }
        if isWorking || isRestarting { return .unavailable(reason: "Wait for the current turn to finish") }
        return .available
    }
}
