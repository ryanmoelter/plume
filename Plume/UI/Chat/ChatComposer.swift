import SwiftUI

/// The chat composer: multiline text, sending on a configurable key.
///
/// A chat that sends on bare Return makes a half-typed multi-line message
/// unrecoverable the instant you press it, where the terminal underneath
/// would have just kept editing. ⌘↩ to send, ↩ to insert a newline, matches
/// the terminal's own forgiveness — the default in `AppSettings.composerSendKey`.
/// Whichever key sends, the other (with Shift) inserts a newline instead.
struct ChatComposer: View, ThemedView {
    @Bindable var task: WorkTask
    let tab: TaskTab
    var isVisible = true

    @FocusState private var inputFocused: Bool
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.theme) var theme
    @State private var settings = AppSettings.shared
    @State private var drafts = DraftStore.shared
    @State private var caretLocation = 0
    @State private var pendingCaretLocation: Int?
    @State private var autocomplete = ComposerAutocompleteController()

    private var headlessSession: HeadlessSession? {
        guard tab.transport == .headless else { return nil }
        return HeadlessSessionManager.shared.existingSession(for: tab.id)
    }

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
        colors.background.map(AnyShapeStyle.init) ?? AnyShapeStyle(.background)
    }

    /// Tracked separately from the draft text so a keystroke does not
    /// invalidate this whole body. The draft changes on every character; only
    /// its emptiness matters here, and that flips twice a message.
    @State private var hasSendableText = false

    private func sendableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableSlashCommands: [SlashCommand] {
        headlessSession?.slashCommands ?? []
    }

    private var composerPlaceholder: String {
        guard let headlessSession, !headlessSession.queuedMessages.isEmpty else {
            return "Message Claude…"
        }
        return "Press ↑ to edit a queued message"
    }

    /// Accepts `command`, replacing the leading `/token` with `/name ` and
    /// moving the caret to the end of it, ahead of any arguments the user
    /// goes on to type.
    private func acceptSlashCommand(_ command: SlashCommand) {
        let tabID = tab.id
        let accepted = SlashCommandMatcher.accepting(command, in: drafts.draft(forTab: tabID))
        drafts.setDraft(accepted.text, forTab: tabID)
        hasSendableText = sendableText(accepted.text)
        pendingCaretLocation = accepted.caretLocation
    }

    /// Pulls a queued message back into the composer for editing — the
    /// operation behind both the queued row's edit button and Up-arrow
    /// recall from an empty composer. Takes an index rather than always the
    /// last message so recall can later walk further back through the queue.
    private func editQueuedMessage(at index: Int) {
        guard let headlessSession, let text = headlessSession.removeQueuedMessage(at: index) else { return }
        drafts.setDraft(text, forTab: tab.id)
        hasSendableText = sendableText(text)
    }

    var body: some View {
        VStack(spacing: dimensions.panelContentInset) {
            if let headlessSession, !headlessSession.queuedMessages.isEmpty {
                queuedMessagesView(headlessSession)
            }

            if autocomplete.isShowing {
                SlashCommandAutocompleteView(
                    commands: autocomplete.matches,
                    selectedIndex: autocomplete.selectedIndex,
                    onSelect: { autocomplete.select($0) }
                )
            }

            VStack(spacing: 0) {
                MarkdownComposerTextView(
                    text: message,
                    placeholder: composerPlaceholder,
                    fontSize: fontSize,
                    isFocused: $inputFocused,
                    sendKey: settings.composerSendKey,
                    onSend: send,
                    onTextChange: { text in
                        let sendable = sendableText(text)
                        if sendable != hasSendableText { hasSendableText = sendable }
                        autocomplete.update(text: text, caretLocation: caretLocation, commands: availableSlashCommands)
                    },
                    onCaretChange: { location in
                        caretLocation = location
                        autocomplete.update(text: drafts.draft(forTab: tab.id), caretLocation: location, commands: availableSlashCommands)
                    },
                    pendingCaretLocation: $pendingCaretLocation,
                    autocompleteHandler: autocomplete,
                    onEditQueuedMessage: headlessSession.flatMap { session in
                        session.queuedMessages.isEmpty ? nil : { editQueuedMessage(at: session.queuedMessages.count - 1) }
                    },
                    recognizedSlashCommandNames: Set(availableSlashCommands.map(\.name))
                )
                // Its own line-fragment padding covers the rest of the
                // field's inset, so the first glyph lands over the control
                // strip's left edge rather than beside it. The text view's
                // vertical inset is the field's top padding.
                .padding(.horizontal, dimensions.composerFieldInset - Self.lineFragmentPadding)
                .accessibilityIdentifier(AccessibilityID.composerField)

                HStack(spacing: dimensions.panelContentInset) {
                    ComposerControlsRow(
                        task: task,
                        tab: tab,
                        headlessSession: headlessSession,
                        isWorkspaceEditable: SurfaceManager.shared.existingSession(for: tab.id) == nil
                            && headlessSession == nil
                    )
                    if headlessSession?.isWorking == true {
                        stopButton
                    }
                    sendButton
                }
                .padding(.horizontal, dimensions.composerFieldInset)
                .padding(.bottom, dimensions.composerFieldInset)
            }
            .background(fieldBackground, in: fieldShape)
            .overlay(fieldShape.strokeBorder(.separator))
        }
        // Content width, matching the prose above it, and inset from the
        // panel's own edge by the same gap the field's rounding is cut to.
        .chatTextColumn()
        .padding(.horizontal, dimensions.panelContentInset)
        .padding(.vertical, dimensions.panelContentInset)
        // Only the visible tab takes focus; hidden tabs stay mounted, and
        // focusing every one of them makes them fight over the input.
        .onChange(of: isVisible, initial: true) { _, visible in
            if visible { inputFocused = true }
        }
        .onAppear {
            autocomplete.onAccept = acceptSlashCommand
        }
    }

    /// `NSTextView` draws its first glyph one line-fragment padding in from
    /// its frame, which the field's own inset has to account for.
    private static let lineFragmentPadding: CGFloat = 5

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: dimensions.composerFieldCornerRadius, style: .continuous)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .frame(width: dimensions.composerControlHeight, height: dimensions.composerControlHeight)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .disabled(!hasSendableText)
        .help("Send")
        .accessibilityLabel("Send")
        .accessibilityIdentifier(AccessibilityID.composerSendButton)
    }

    /// Matches `sendButton`'s size and shape but not its accent-colored fill,
    /// so the pair reads as two related controls with send as the primary.
    private var stopButton: some View {
        Button {
            headlessSession?.interrupt()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .frame(width: dimensions.composerControlHeight, height: dimensions.composerControlHeight)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help("Stop the current turn")
        .accessibilityLabel("Stop")
        .accessibilityIdentifier(AccessibilityID.composerStopButton)
    }

    private func send() {
        guard hasSendableText else { return }
        let text = drafts.draft(forTab: tab.id)
        drafts.setDraft("", forTab: tab.id)
        if let headlessSession {
            headlessSession.submit(text: text)
        } else if let session = SurfaceManager.shared.existingSession(for: tab.id) {
            session.submit(text: text)
        } else {
            AgentLauncher.launch(message: text, task: task, tab: tab)
        }
    }

    private func queuedMessagesView(_ session: HeadlessSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(session.queuedMessages.enumerated()), id: \.offset) { index, message in
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .emphasis(.secondary)
                    Text(message)
                        .lineLimit(1)
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button {
                        editQueuedMessage(at: index)
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .emphasis(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit")
                    Button {
                        session.removeQueuedMessage(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .emphasis(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                }
            }
        }
        .padding(.horizontal, dimensions.composerFieldInset)
        .padding(.vertical, dimensions.panelContentInset)
        .background(.quaternary, in: .rect(cornerRadius: dimensions.composerFieldCornerRadius, style: .continuous))
    }
}

#Preview {
    ChatComposer(task: WorkTask(title: "Preview", orderIndex: 0), tab: TaskTab(kind: .agent, orderIndex: 0))
        .padding()
}
