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

    @State private var message = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.chatFontSize) private var fontSize
    @State private var settings = AppSettings.shared

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            WorkspacePickerView(
                task: task,
                isEditable: SurfaceManager.shared.existingSession(for: tab.id) == nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .bottom, spacing: 8) {
                MarkdownComposerTextView(
                    text: $message,
                    placeholder: "Message Claude…",
                    fontSize: fontSize,
                    isFocused: $inputFocused,
                    sendKey: settings.composerSendKey,
                    onSend: send
                )
                .padding(.horizontal, 6)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
        .frame(maxWidth: ChatMetrics.maxContentWidth(forFontSize: fontSize))
        .frame(maxWidth: .infinity)
        .padding(10)
        // Only the visible tab takes focus; hidden tabs stay mounted, and
        // focusing every one of them makes them fight over the input.
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible { inputFocused = true }
        }
    }

    private func send() {
        guard canSend else { return }
        let text = message
        message = ""
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
