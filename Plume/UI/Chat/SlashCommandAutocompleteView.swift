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
    /// Nothing between it and the panel's top edge, so it owes that edge the
    /// same inset it gives the sides. With the queued-messages strip above,
    /// the row spacing sets the gap instead.
    var isTopOfPanel = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == selectedIndex)
                            .id(index)
                            .onTapGesture { onSelect(index) }
                    }
                }
                .padding(rowInset)
            }
            .onChange(of: selectedIndex, initial: true) { _, newValue in
                proxy.scrollTo(newValue)
            }
        }
        .frame(maxHeight: 200)
        .background(washColor, in: shape)
        .overlay { shape.strokeBorder(.separator) }
        .padding(.horizontal, -textInset)
        .padding(.top, isTopOfPanel ? -textInset : 0)
    }

    /// What a row's text pays inside the box before it starts.
    private var textInset: CGFloat { rowInset + dimensions.panelContentInset }

    /// The box steps out past the composer by everything its text pays
    /// inside it, so a command reads down the same edge as the message being
    /// typed. Its corner then cuts concentric to the panel at that smaller
    /// inset rather than at the composer's.
    private var boxCornerRadius: CGFloat {
        ComposerPanelMetrics.concentricRadius(
            outer: dimensions.panelCornerRadius,
            inset: dimensions.composerFieldInset - textInset
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: boxCornerRadius, style: .continuous)
    }

    private let rowInset: CGFloat = 4

    private func row(_ command: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("/\(command.name)")
                .font(typography.caption.monoMedium)
            if command.isPlumeProvided {
                // Plume runs this one itself; the CLI has never heard of it.
                Image(systemName: "apple.terminal.fill")
                    .imageScale(.small)
                    .emphasis(.secondary)
                    .help("Handled by Plume")
            }
            if !command.description.isEmpty {
                Text(command.description)
                    .font(typography.caption.font)
                    .emphasis(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, dimensions.panelContentInset)
        .padding(.vertical, 5)
        .background(
            isSelected ? colors.selection.emphasized(.divider, in: colors) : .clear,
            in: .rect(
                cornerRadius: ComposerPanelMetrics.concentricRadius(
                    outer: boxCornerRadius,
                    inset: rowInset
                ),
                style: .continuous
            )
        )
        .contentShape(.rect)
    }

    private var washColor: AnyShapeStyle {
        colors.background.map(AnyShapeStyle.init) ?? AnyShapeStyle(.regularMaterial)
    }
}
