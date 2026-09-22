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

    /// Tracked separately from the draft text so a keystroke does not
    /// invalidate this whole body. The draft changes on every character; only
    /// its emptiness matters here, and that flips twice a message.
    @State private var hasSendableText = false

    private func sendableText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var attachedImages: [ChatImage] {
        drafts.attachments(forTab: tab.id)
    }

    /// An image alone is a message worth sending, so the send button tracks
    /// both halves of the draft.
    private var canSend: Bool {
        hasSendableText || !attachedImages.isEmpty
    }

    /// Images ride only on the headless transport. A terminal tab's input is
    /// a paste into a real TUI, which has no way to carry one.
    private var acceptsImages: Bool {
        tab.transport == .headless
    }

    private func attach(_ images: [ChatImage]) {
        drafts.attach(images, toTab: tab.id)
    }

    private var attachHandler: (([ChatImage]) -> Void)? {
        guard acceptsImages else { return nil }
        let drafts = drafts
        let tabID = tab.id
        return { drafts.attach($0, toTab: tabID) }
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

    private var isCommandMode: Bool {
        drafts.isCommandMode(forTab: tab.id)
    }

    /// Enters command mode when a draft starts with `!`, taking the `!` out
    /// of the text: the chip and the monospaced field say what mode this is,
    /// so the marker has nothing left to add.
    private func updateCommandMode(for text: String) {
        guard !isCommandMode, tab.transport == .headless else { return }
        guard let stripped = CommandModeMatcher.enteringCommandMode(text) else { return }
        drafts.setCommandMode(true, forTab: tab.id)
        drafts.setDraft(stripped, forTab: tab.id)
        hasSendableText = sendableText(stripped)
        pendingCaretLocation = max(0, caretLocation - 1)
    }

    private var composerPlaceholder: String {
        if isCommandMode { return "Run a shell command…" }
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
        guard let headlessSession, let blocks = headlessSession.removeQueuedMessage(at: index) else { return }
        let text = blocks.plainText
        drafts.setDraft(text, forTab: tab.id)
        attach(blocks.compactMap { if case .image(let image) = $0 { image } else { nil } })
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
                if !attachedImages.isEmpty {
                    ComposerAttachmentStrip(
                        images: attachedImages,
                        onRemove: { drafts.removeAttachment(at: $0, fromTab: tab.id) }
                    )
                    .padding(.bottom, dimensions.panelContentInset)
                }
                if isCommandMode {
                    commandModeChip
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
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
                        updateCommandMode(for: text)
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
                    recognizedSlashCommandNames: Set(availableSlashCommands.map(\.name)),
                    onAttachImages: attachHandler,
                    isCommandMode: isCommandMode,
                    onDeleteBackwardWhenEmpty: isCommandMode
                        ? { drafts.setCommandMode(false, forTab: tab.id) }
                        : nil
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
            .animation(.snappy(duration: 0.2), value: isCommandMode)
            // Anchored to the bottom: the panel is pinned to the bottom of
            // the chat, so the chip has to grow the panel upwards. Easing the
            // height from the centre splits the change across both edges and
            // drags the controls row with it.
            .animatedHeight(.snappy(duration: 0.2), alignment: .bottom)
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
        .disabled(!canSend)
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

    /// Says what the composer will do with what is being typed. Its button
    /// leaves the mode, as Delete in an empty field does.
    private var commandModeChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(typography.caption.font)
            Text("bash command")
                .font(typography.caption.font)
            Button {
                drafts.setCommandMode(false, forTab: tab.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(typography.caption.font)
            }
            .buttonStyle(.plain)
            .help("Leave command mode")
            .accessibilityLabel("Leave command mode")
        }
        .emphasis(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, dimensions.panelContentInset)
    }

    private func send() {
        guard canSend else { return }
        let text = drafts.draft(forTab: tab.id)
        let images = attachedImages
        drafts.setDraft("", forTab: tab.id)
        drafts.clearAttachments(forTab: tab.id)
        hasSendableText = false
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
        // Command mode, headless only: a terminal tab's composer feeds the
        // real TUI, whose own bash mode already handles a leading `!`.
        if isCommandMode {
            drafts.setCommandMode(false, forTab: tab.id)
            if let command = CommandModeMatcher.parse(text) {
                runCommand(command)
                return
            }
        }
        let blocks: [UserContentBlock] =
            [.text(CommandModeMatcher.unescaped(text))] + images.map { .image($0) }
        dispatch(blocks)
    }

    /// Runs a command-mode command and hands the agent what it printed, so
    /// the result lands in the transcript rather than only on screen.
    ///
    /// Detached from `send` so the composer clears at once: the command owns
    /// however long it takes to run, and `ChatTabView` shows it meanwhile.
    ///
    /// The command and its output go as one turn, tagged the way the CLI's
    /// own bash mode writes them, so the agent reads them as a shell command
    /// rather than as prose quoting one.
    private func runCommand(_ command: String) {
        let tabID = tab.id
        let runID = CommandModeRuns.shared.start(
            command,
            in: TabDirectoryStore.shared.directory(for: tab),
            tabID: tabID
        ) { result in
            // Sent outright rather than queued, so the transcript takes over
            // telling the story and the chip has nothing left to say. Read
            // from the delivery, not from `isWorking` afterwards: sending
            // starts a turn, which would make every send look like a queue.
            if dispatch([.text(result.transcriptText)]) == .sent {
                CommandModeRuns.shared.finish(runID, tabID: tabID)
            }
        }
    }

    /// Sends `blocks` to whichever backend the tab has, launching one when
    /// it has none. Only a headless session can queue; the other two paths
    /// deliver outright.
    @discardableResult
    private func dispatch(_ blocks: [UserContentBlock]) -> HeadlessSession.Delivery {
        let text = blocks.plainText
        if let headlessSession {
            return headlessSession.submit(blocks: blocks)
        } else if let session = SurfaceManager.shared.existingSession(for: tab.id) {
            session.submit(text: text)
        } else {
            onLaunch(text)
            AgentLauncher.launch(blocks: blocks, task: task, tab: tab)
        }
        return .sent
    }
}

#Preview {
    ChatComposer(task: WorkTask(title: "Preview", orderIndex: 0), tab: TaskTab(kind: .agent, orderIndex: 0))
        .padding()
}
