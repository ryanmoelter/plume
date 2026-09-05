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
    }

    /// Floats over the glass panel at the composer's own inset, so its
    /// corner takes the radius concentric with the panel at that inset — the
    /// same one the queued-messages strip uses. Its rows are inset inside it
    /// and take a concentric radius of their own.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: dimensions.composerFieldCornerRadius, style: .continuous)
    }

    private let rowInset: CGFloat = 4

    private func row(_ command: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("/\(command.name)")
                .font(typography.caption.monoMedium)
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
                    outer: dimensions.composerFieldCornerRadius,
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
