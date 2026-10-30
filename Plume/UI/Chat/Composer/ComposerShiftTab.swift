import Foundation

/// Shift-Tab is claimed by an open autocomplete, then by a list item's
/// outdent, and only otherwise cycles the permission mode.
nonisolated enum ComposerShiftTab {
    enum Action: Equatable {
        case autocomplete
        case outdent(ComposerMarkdownEditing.Result)
        case cycleMode
        case ordinary
    }

    static func decide(
        autocompleteShowing: Bool,
        outdent: ComposerMarkdownEditing.Result?,
        canCycleMode: Bool
    ) -> Action {
        if autocompleteShowing { return .autocomplete }
        if let outdent { return .outdent(outdent) }
        return canCycleMode ? .cycleMode : .ordinary
    }

    /// The option after `current`, wrapping; the first when `current` is not
    /// offered. Nil when there is nothing to move to.
    static func next<Option: Equatable>(after current: Option?, in options: [Option]) -> Option? {
        guard options.count > 1 || (options.count == 1 && options[0] != current) else { return nil }
        guard let current, let index = options.firstIndex(of: current) else { return options.first }
        return options[(index + 1) % options.count]
    }
}
