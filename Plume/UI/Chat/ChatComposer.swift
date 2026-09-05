import Dispatch
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
    /// Whether something else in the panel already sits above the composer
    /// (the docked plan bar) — the caller is the only one who knows.
    var hasContentAbove = false
    /// Set by `ChatTabView` to pull a queued message (rendered there, above
    /// the panel) back into the draft for editing — the same operation the
    /// Up-arrow recall path below already does, since only this view knows
    /// how to keep `hasSendableText` in sync with the draft it writes.
    var editQueuedMessageIndex: Binding<Int?> = .constant(nil)
    /// Forwarded straight to `ComposerControlsRow` — see its own doc comment.
    var showsPlanButton = false
    var onOpenPlan: () -> Void = {}
    /// The message that just launched the agent, so the caller can open the
    /// conversation on it rather than waiting for the transcript. Fires only
    /// on the launch path, which is a tab's first message.
    var onLaunch: (String) -> Void = { _ in }

    @State private var inputFocused = false
    @Environment(\.chatFontSize) private var fontSize
    @Environment(\.theme) var theme
    @State private var settings = AppSettings.shared
    @State private var drafts = DraftStore.shared
    @State private var commandMemory = SlashCommandMemory.shared
    @State private var tabDirectories = TabDirectoryStore.shared
    @State private var caretLocation = 0
    @State private var pendingCaretLocation: Int?
    @State private var autocomplete = ComposerAutocompleteController()

    private var headlessSession: (any AgentSession)? {
        guard tab.transport == .headless else { return nil }
        return AgentSessionManager.shared.existingSession(for: tab.id)
    }

    private var message: Binding<String> {
        let drafts = drafts
        let tabID = tab.id
        return Binding(
            get: { drafts.draft(forTab: tabID) },
            set: { drafts.setDraft($0, forTab: tabID) }
        )
    }

    /// Tracked separately from the draft text so a keystroke does not
    /// invalidate this whole body. The draft changes on every character; only
    /// its emptiness matters here, and that flips twice a message.
    @State private var hasSendableText = false

    private func sendableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The CLI's commands, from this session when it has reported and from
    /// the last one to report in this tab's directory until then, so a cold
    /// tab still completes them.
    ///
    /// Plume's own join them only once a session exists to run them against —
    /// `/rc` drives a control request, which has no process to reach without
    /// one — and never shadow a name the CLI reports: if a later CLI serves
    /// `/rc` headlessly, its version wins.
    private var availableSlashCommands: [SlashCommand] {
        guard tab.transport == .headless else { return [] }
        let remembered = commandMemory.commands(inDirectory: tabDirectories.directory(for: tab))
        guard let headlessSession else { return remembered }
        let reported = headlessSession.slashCommands.isEmpty
            ? remembered
            : headlessSession.slashCommands
        let reportedNames = Set(reported.map(\.name))
        return reported + PlumeSlashCommand.all.filter { !reportedNames.contains($0.name) }
    }

    /// True while the CLI list on offer is the last session's rather than this
    /// one's, so the popup can say the names are a guess.
    private var slashCommandsAreRemembered: Bool {
        headlessSession?.slashCommands.isEmpty ?? true
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
            if autocomplete.isShowing {
                SlashCommandAutocompleteView(
                    commands: autocomplete.matches,
                    selectedIndex: autocomplete.selectedIndex,
                    onSelect: { autocomplete.select($0) },
                    isTopOfPanel: !hasContentAbove,
                    isRemembered: slashCommandsAreRemembered
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
                // Its own line-fragment padding already covers part of the
                // composer's inset, so the first glyph lands over the control
                // strip's left edge rather than beside it. Its vertical inset
                // comes from its own `textContainerInset`, not from here.
                .padding(.horizontal, -Self.lineFragmentPadding)
                .accessibilityIdentifier(AccessibilityID.composerField)

                HStack(spacing: dimensions.panelContentInset) {
                    ComposerControlsRow(
                        task: task,
                        tab: tab,
                        headlessSession: headlessSession,
                        showsPlanButton: showsPlanButton,
                        onOpenPlan: onOpenPlan
                    )
                    if headlessSession?.isWorking == true {
                        stopButton
                    }
                    sendButton
                }
                .padding(.top, dimensions.panelContentInset)
            }
        }
        // The composer's whole content sits at one inset from the glass
        // edge, on every side — the text view's own correction above is what
        // keeps its glyphs level with the controls below it.
        .padding(dimensions.composerFieldInset)
        // Only the visible tab takes focus; hidden tabs stay mounted, and
        // focusing every one of them makes them fight over the input.
        //
        // Deferred a tick: a new tab replaces the previous one in the same
        // `ForEach` update (headless chat unmounts a hidden tab rather than
        // just hiding it), so the outgoing view is still resigning real
        // first responder when this fires. Claiming it in the same
        // transaction loses the race silently; the next run loop turn wins it.
        .onChange(of: isVisible, initial: true) { _, visible in
            guard visible else { return }
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: editQueuedMessageIndex.wrappedValue) { _, index in
            guard let index else { return }
            editQueuedMessage(at: index)
            editQueuedMessageIndex.wrappedValue = nil
        }
        .onAppear {
            autocomplete.onAccept = acceptSlashCommand
        }
    }

    /// `NSTextView` draws its first glyph one line-fragment padding in from
    /// its frame, which the composer's own inset has to account for.
    private static let lineFragmentPadding: CGFloat = 5

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
        // Only on the headless transport: a terminal tab's composer feeds the
        // real TUI, where `/rc` already works. And only with a session live —
        // the launch path below is a tab's first message, which has no bridge
        // to attach to, so the command is dropped rather than sent as prose.
        if tab.transport == .headless, let command = PlumeSlashCommand.parse(text) {
            guard let headlessSession else { return }
            switch command {
            case .remoteControl(let name):
                headlessSession.setRemoteControl(
                    enabled: !headlessSession.remoteControl.isConnected,
                    name: name
                )
            }
            return
        }
        if let headlessSession {
            headlessSession.submit(text: text)
        } else if let session = SurfaceManager.shared.existingSession(for: tab.id) {
            session.submit(text: text)
        } else {
            onLaunch(text)
            AgentLauncher.launch(message: text, task: task, tab: tab)
        }
    }
}

#Preview {
    ChatComposer(task: WorkTask(title: "Preview", orderIndex: 0), tab: TaskTab(kind: .agent, orderIndex: 0))
        .padding()
}
