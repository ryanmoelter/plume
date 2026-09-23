import Foundation

/// Bridges the AppKit key-handling path (`ComposerAutocompleteHandler`,
/// called from `keyDown`) to the SwiftUI-observed state the composer
/// renders. Recomputed from scratch on every keystroke and caret move —
/// filtering a session's command list is cheap enough that a diff isn't
/// worth the complexity.
@Observable
final class ComposerAutocompleteController: ComposerAutocompleteHandler {
    private(set) var matches: [SlashCommand] = []
    private(set) var selectedIndex = 0

    /// Set by the composer so `acceptSelection` can insert the chosen
    /// command's name into the actual text, which this controller doesn't
    /// own.
    var onAccept: (SlashCommand) -> Void = { _ in }

    var isShowing: Bool { !matches.isEmpty }

    func update(text: String, caretLocation: Int, commands: [SlashCommand], prefix: String = "/") {
        guard !commands.isEmpty, let query = SlashCommandMatcher.query(text: text, caretLocation: caretLocation, prefix: prefix) else {
            matches = []
            selectedIndex = 0
            return
        }
        matches = SlashCommandMatcher.matches(query: query, in: commands)
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
        acceptSelection()
    }

    func acceptSelection() {
        guard matches.indices.contains(selectedIndex) else { return }
        onAccept(matches[selectedIndex])
        matches = []
        selectedIndex = 0
    }

    func dismiss() {
        matches = []
        selectedIndex = 0
    }
}
