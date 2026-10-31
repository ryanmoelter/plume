import SwiftUI

/// Home's quick start: the chat composer on Home's own tab
/// (`HomeComposerTab`), plus a destination, sent as a new task's first
/// message.
struct HomeComposer: View, ThemedView {
    let model: HomeComposerModel
    /// False when the task could not start, so the composer puts the message
    /// back.
    let onSend: (ComposerHandOff.Message) async -> Bool

    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    private let home = HomeComposerTab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: dimensions.panelContentInset) {
            GlassEffectContainer(spacing: 0) {
                composer
                    .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(typography.caption.font)
                    .foregroundStyle(colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, dimensions.composerFieldInset)
                    .plumeID(AccessibilityID.homeComposerError, value: error)
            }
        }
        .onChange(of: model.destination.projectPath, initial: true) { _, path in
            home.setDirectory(path)
        }
    }

    private var composer: some View {
        ChatComposer(
            task: home.task,
            tab: home.tab,
            suggestionDirection: .down,
            handOff: ComposerHandOff(
                placeholder: "Start a new task…",
                isReady: model.canStart,
                send: onSend
            ),
            aboveField: AnyView(HomeDestinationPath(model: model))
        )
    }

    private var glass: Glass {
        ThemeChrome.background(for: colorScheme).map { Glass.regular.tint($0.opacity(0.5)) } ?? .regular
    }
}
