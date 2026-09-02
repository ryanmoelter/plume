import SwiftUI

/// Filtered slash-command list shown above the composer while the caret
/// sits in a leading `/token`. Purely a rendering of already-matched
/// commands and a selected index — all matching and key handling live
/// elsewhere.
struct SlashCommandAutocompleteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let commands: [SlashCommand]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    row(command, isSelected: index == selectedIndex)
                        .onTapGesture { onSelect(index) }
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 200)
        .background(washColor, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
        }
    }

    private func row(_ command: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("/\(command.name)")
                .font(.system(size: chatFontSize * 0.85, weight: .medium, design: .monospaced))
            if !command.description.isEmpty {
                Text(command.description)
                    .font(.system(size: chatFontSize * 0.78))
                    .emphasis(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected ? ChatRole.selection.emphasized(.divider, colorScheme: colorScheme) : .clear,
            in: .rect(cornerRadius: 5)
        )
        .contentShape(.rect)
    }

    private var washColor: AnyShapeStyle {
        ThemeChrome.background(for: colorScheme).map(AnyShapeStyle.init) ?? AnyShapeStyle(.regularMaterial)
    }
}
