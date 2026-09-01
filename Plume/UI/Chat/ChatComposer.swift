import SwiftUI

/// The chat composer: multiline text, sending on ⌘↩ rather than plain ↩.
///
/// A chat that sends on bare Return makes a half-typed multi-line message
/// unrecoverable the instant you press it, where the terminal underneath
/// would have just kept editing. ⌘↩ to send, ↩ to insert a newline, matches
/// the terminal's own forgiveness.
struct ChatComposer: View {
    @Bindable var task: WorkTask
    let tab: TaskTab
    var isVisible = true

    @State private var message = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.chatFontSize) private var fontSize

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MarkdownComposerTextView(
                text: $message,
                placeholder: "Message Claude…",
                fontSize: fontSize,
                isFocused: $inputFocused,
                onSend: send
            )
            .padding(.horizontal, 6)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
        }
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
