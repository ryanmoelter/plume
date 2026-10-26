import SwiftUI

/// Filtered slash-command list shown above the composer while the caret
/// sits in a leading `/token`. Purely a rendering of already-matched
/// commands and a selected index — all matching and key handling live
/// elsewhere.
struct SlashCommandAutocompleteView: View, ThemedView {
    @Environment(\.theme) var theme

    let commands: [SlashCommand]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    var isTopOfPanel = true
    /// True while these names come from the last session rather than this
    /// one, so the list says so instead of presenting a guess as fact.
    var isRemembered = false
    var tokenPrefix = "/"

    var body: some View {
        ComposerSuggestionPanel(
            items: commands,
            selectedIndex: selectedIndex,
            onSelect: onSelect,
            isTopOfPanel: isTopOfPanel,
            footer: isRemembered ? "From the last session — not yet confirmed by Claude Code" : nil,
            row: row
        )
    }

    private func row(_ command: SlashCommand) -> some View {
        HStack(spacing: 8) {
            Text("\(tokenPrefix)\(command.name)")
                .font(typography.caption.monoMedium)
            if command.isPlumeProvided {
                // Plume runs this one itself; the CLI has never heard of it.
                Image(systemName: "apple.terminal.fill")
                    .imageScale(.small)
                    .emphasis(.secondary)
                    .help("Handled by \(AppIdentity.displayName)")
            }
            if !command.description.isEmpty {
                Text(command.description)
                    .font(typography.caption.font)
                    .emphasis(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
