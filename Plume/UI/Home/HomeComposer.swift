import SwiftUI

/// Home's quick start: a message and a destination, sent as a new task's
/// first message.
///
/// The chat's text view without `ChatComposer` around it: that view keeps its
/// draft, mentions, slash commands and controls per tab, and there is no tab
/// until this sends.
struct HomeComposer: View, ThemedView {
    let model: HomeComposerModel
    let variant: HomeComposerVariant
    let placement: HomeComposerPlacement
    /// False when the task could not start, so the text goes back in the field.
    let onSend: (String) async -> Bool

    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = AppSettings.shared
    @State private var text = ""
    @State private var hasSendableText = false
    @State private var isFocused = false

    private var canSend: Bool { hasSendableText && model.canStart }

    var body: some View {
        VStack(alignment: .leading, spacing: dimensions.panelContentInset) {
            MarkdownComposerTextView(
                text: $text,
                placeholder: "Start a new task…",
                fontSize: CGFloat(settings.chatFontSize),
                isFocused: $isFocused,
                sendKey: settings.composerSendKey,
                onSend: send,
                onTextChange: { text in
                    let sendable = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if sendable != hasSendableText { hasSendableText = sendable }
                }
            )
            // The text view's line-fragment padding, so its first glyph sits
            // over the controls' leading edge.
            .padding(.horizontal, -5)
            .plumeID(AccessibilityID.homeComposerField)

            HStack(spacing: dimensions.panelContentInset) {
                picker
                Spacer(minLength: 0)
                if model.isStarting {
                    ProgressView().controlSize(.small)
                }
                sendButton
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(typography.caption.font)
                    .foregroundStyle(colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .plumeID(AccessibilityID.homeComposerError, value: error)
            }
        }
        .padding(dimensions.composerFieldInset)
        .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
    }

    private var glass: Glass {
        ThemeChrome.background(for: colorScheme).map { Glass.regular.tint($0.opacity(0.5)) } ?? .regular
    }

    @ViewBuilder
    private var picker: some View {
        switch variant {
        case .chipRow: HomeDestinationChipRow(model: model)
        case .destinationChip: HomeDestinationChip(model: model, placement: placement)
        case .breadcrumb: HomeDestinationBreadcrumb(model: model)
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .frame(width: dimensions.composerControlHeight, height: dimensions.composerControlHeight)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .help("Start the task")
        .accessibilityLabel("Start")
        .plumeID(AccessibilityID.homeComposerSendButton, invoke: send)
        .disabled(!canSend)
    }

    private func send() {
        guard canSend else { return }
        let message = text
        text = ""
        hasSendableText = false
        Task {
            guard !(await onSend(message)), text.isEmpty else { return }
            text = message
            hasSendableText = true
        }
    }
}
