import SwiftUI

/// The chat composer: multiline text, sending on a configurable key.
///
/// A chat that sends on bare Return makes a half-typed multi-line message
/// unrecoverable the instant you press it, where the terminal underneath
/// would have just kept editing. ⌘↩ to send, ↩ to insert a newline, matches
/// the terminal's own forgiveness — the default in `AppSettings.composerSendKey`.
/// Whichever key sends, the other (with Shift) inserts a newline instead.
struct ChatComposer: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    var isVisible = true

    @FocusState private var inputFocused: Bool
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = AppSettings.shared
    @State private var drafts = DraftStore.shared

    private var message: Binding<String> {
        let drafts = drafts
        let tabID = tab.id
        return Binding(
            get: { drafts.draft(forTab: tabID) },
            set: { drafts.setDraft($0, forTab: tabID) }
        )
    }

    /// The terminal's own background, so the field matches the surface it
    /// sends to. Falls back to standard chrome when no theme is configured.
    private var fieldBackground: AnyShapeStyle {
        ThemeChrome.background(for: colorScheme).map(AnyShapeStyle.init) ?? AnyShapeStyle(.background)
    }

    /// Tracked separately from the draft text so a keystroke does not
    /// invalidate this whole body. The draft changes on every character; only
    /// its emptiness matters here, and that flips twice a message.
    @State private var hasSendableText = false

    private func sendableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            WorkspacePickerView(
                task: task,
                isEditable: SurfaceManager.shared.existingSession(for: tab.id) == nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            MarkdownComposerTextView(
                text: message,
                placeholder: "Message Claude…",
                fontSize: fontSize,
                isFocused: $inputFocused,
                sendKey: settings.composerSendKey,
                onSend: send,
                onTextChange: { text in
                    let sendable = sendableText(text)
                    if sendable != hasSendableText { hasSendableText = sendable }
                }
            )
            .padding(.leading, 10)
            // Reserves the send button's column, so text wraps before it
            // reaches the button rather than running underneath.
            .padding(.trailing, Self.sendButtonDiameter + 18)
            .background(fieldBackground, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .overlay(alignment: .trailing) {
                sendButton.padding(.trailing, 8)
            }
        }
        .listItemPadding(bleed: true)
        // Only the visible tab takes focus; hidden tabs stay mounted, and
        // focusing every one of them makes them fight over the input.
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible { inputFocused = true }
        }
    }

    private static let sendButtonDiameter: CGFloat = 22

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .frame(width: Self.sendButtonDiameter, height: Self.sendButtonDiameter)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .disabled(!hasSendableText)
        .help("Send")
        .accessibilityLabel("Send")
    }

    private func send() {
        guard hasSendableText else { return }
        let text = drafts.draft(forTab: tab.id)
        drafts.setDraft("", forTab: tab.id)
        if let session = SurfaceManager.shared.existingSession(for: tab.id) {
            session.submit(text: text)
        } else {
            AgentLauncher.launch(message: text, task: task, tab: tab)
        }
    }
}

#Preview {
    ChatComposer(task: WorkTask(title: "Preview", orderIndex: 0), tab: TaskTab(kind: .agent, orderIndex: 0))
        .padding()
}
