import SwiftUI

/// The chat rendering of an agent tab: the messages, with a floating panel
/// over them carrying the composer above the statusline strip, and the plan
/// dock tucked behind it when a plan is waiting on a decision. The
/// conversation scrolls behind the glass rather than stopping at its top edge.
struct ChatTabView: View, ThemedView {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var settings = AppSettings.shared
    @State private var planPresentation = PlanPresentation.hidden(.closed)
    /// The last plan proposal the user answered here, so the footer can say
    /// where it landed once the live request is gone. Nil until they answer
    /// one in this tab — a plan approved before the app launched reads as
    /// "not approved yet" rather than claiming an approval we never saw.
    @State private var settledPlan: PlanApprovalState.Proposal?
    @State private var planRejectionReason = ""
    /// The plan file, read once for both the overlay that renders it and the
    /// dock bar that names it. Followed whenever a plan exists, not only while
    /// the overlay is up: the dock bar is what shows when it is not.
    @State private var planFile = MarkdownFileStore()
    @State private var planFeedbackFocused = false
    @State private var resumeSheetShown = false
    /// The subagent whose transcript is open over the chat, by id — held as an
    /// id rather than the value so the overlay follows the subagent's live
    /// re-reads instead of freezing at the moment it was opened.
    @State private var openSubagentID: String?
    @State private var untrustedDirectoryStore = UntrustedDirectoryStore.shared
    /// The first message, from the moment it is sent until the transcript
    /// contains it. Held here rather than on the session because it has to
    /// outlive a launch that never produces one.
    @State private var pendingFirstMessage: OptimisticFirstMessage?
    /// The measured height of the floating bottom chrome — the queued-message
    /// chips plus the panel beneath them — so the list can inset its content
    /// past it. Nothing in that subtree is sized from it, so measuring
    /// cannot feed back into the measurement.
    @State private var panelHeight: CGFloat = 0
    /// Set to pull a queued message back into the composer for editing, from
    /// the chip's own edit button. `ChatComposer` owns the actual draft/state
    /// sync (`editQueuedMessage(at:)`) since it also serves the Up-arrow
    /// recall path; this only carries the request across.
    @State private var editQueuedMessageIndex: Int?
    /// The dock bar and the expanded overlay are separate view trees, so the
    /// namespace the zoom between them matches on lives here, above both.
    @Namespace private var planZoom

    private var untrustedPath: String? {
        untrustedDirectoryStore.path(forTab: tab.id)
    }

    private var transcript: Transcript? {
        TranscriptStore.shared.transcript(forTab: tab.id)
    }

    private var transcriptMessages: [ChatMessage] {
        transcript?.messages ?? []
    }

    /// What the chat renders: the transcript, plus the first message while it
    /// is still in flight. `OptimisticChatReconciler` decides which — the
    /// pending copy disappears the moment the transcript carries the line, so
    /// the two are never both on screen.
    private var conversationMessages: [ChatMessage] {
        OptimisticChatReconciler.messages(
            transcript: transcriptMessages,
            pending: pendingFirstMessage
        )
    }

    /// The transcript's plan path is a stale snapshot from when the line was
    /// written, so the file may be gone. The existence check is cached rather
    /// than run inline: this is read from `body`, and touching the filesystem
    /// on every render pass is not free.
    private var planFilePath: String? {
        guard let path = transcript?.planFilePath else { return nil }
        return PlanFileExistence.exists(path) ? path : nil
    }

    /// The live `ExitPlanMode` request, when the agent is waiting on one.
    private var pendingPlan: PendingPermission? {
        headlessSession?.pendingPermissions.first { permission in
            if case .plan = permission.interactive { return true }
            return false
        }
    }

    /// Where the plan stands, for the overlay's footer. A live request
    /// outranks a remembered answer: a fresh proposal after an approval puts
    /// the footer back to awaiting a decision.
    private var planApproval: PlanApprovalState {
        if let pendingPlan {
            return .derive(latestProposal: .init(toolUseID: pendingPlan.id))
        }
        return .derive(latestProposal: settledPlan)
    }

    /// Only reached from the empty state, which renders while the tab has no
    /// transcript at all — so unlike the plan path, this is not on the
    /// streaming render path and can check the filesystem directly.
    private var canResume: Bool {
        guard let directory = task.workingDirectoryPath else { return false }
        return FileManager.default.fileExists(atPath: directory)
    }

    private var subagents: [SubagentTranscript] {
        TranscriptStore.shared.subagents(forTab: tab.id)
    }

    private var openSubagent: SubagentTranscript? {
        guard let openSubagentID else { return nil }
        return subagents.first { $0.id == openSubagentID }
    }

    /// The transcript's own `cwd` follows the agent, including through
    /// `EnterWorktree`; the task's path only covers the window before any
    /// transcript exists.
    private var gitDirectory: String? {
        transcript?.cwd ?? task.workingDirectoryPath
    }

    /// The main agent's own status, ignoring its subagents — what the chat's
    /// working indicator should track. The sidebar shows the aggregated form
    /// instead: a working subagent alone should not make the conversation
    /// claim the main agent is still speaking.
    private var status: TaskStatus {
        StatusEngine.shared.ownStatus(forTab: tab.id)
    }

    private var headlessSession: (any AgentSession)? {
        guard tab.transport == .headless else { return nil }
        return AgentSessionManager.shared.existingSession(for: tab.id)
    }

    /// Which of the tab's states is on screen. An optimistic first message is
    /// enough to reach the conversation, so the transcript is not what decides
    /// it — `conversationMessages` is.
    @ViewBuilder
    private var content: some View {
        if !conversationMessages.isEmpty {
            conversationView(messages: conversationMessages)
        } else if let untrustedPath {
            untrustedDirectoryState(path: untrustedPath)
        } else if let startFailure = agentSession?.startFailure {
            startFailureState(startFailure)
        } else if SurfaceManager.shared.existingSession(for: tab.id) != nil
            || AgentSessionManager.shared.existingSession(for: tab.id) != nil
            || (tab.agentSessionID?.isEmpty == false) {
            // A process (or a resumable session) exists but has written no
            // transcript content yet — nothing to show but a quiet wait.
            emptyState(isComposerEnabled: false)
        } else {
            emptyState(isComposerEnabled: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The tracking rides on `content` rather than on the chain below,
            // which is already at the type-checker's limit.
            content
                .modifier(OptimisticFirstMessageTracking(
                    messages: transcriptMessages,
                    startFailure: agentSession?.startFailure,
                    pending: $pendingFirstMessage
                ))
        }
        .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .chatLinkHandling(directory: gitDirectory.map { URL(fileURLWithPath: $0) })
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .onAppear { registerWatchIfNeeded() }
        .onChange(of: gitDirectory, initial: true) { previous, current in
            if let previous { GitStateStore.shared.release(previous) }
            if let current { GitStateStore.shared.watch(current) }
            TabDirectoryStore.shared.setDirectory(current, forTab: tab)
        }
        .onDisappear {
            if let gitDirectory { GitStateStore.shared.release(gitDirectory) }
        }
        .onChange(of: planFilePath, initial: true) { _, path in
            if let path { planFile.watch(path: path) } else { planFile.stop() }
        }
        .onChange(of: tab.sessionJSONLPath) { _, _ in registerWatchIfNeeded() }
        // The store re-points a session that has moved between project
        // directories; persisting it here keeps a restart and the title
        // monitor on the same file.
        .onChange(of: TranscriptStore.shared.watchedPath(forTab: tab.id)) { _, watched in
            guard let watched, !watched.isEmpty, tab.sessionJSONLPath != watched else { return }
            tab.sessionJSONLPath = watched
        }
        // Only fires once per completed turn, not per stream event, so this
        // is already the debounced write the rest of the app requires.
        .onChange(of: headlessSession?.contextWindow) { _, window in
            guard let window, tab.contextWindowTokens != window else { return }
            tab.contextWindowTokens = window
        }
        .onChange(of: headlessSession?.permissionMode) { _, mode in
            guard let mode, tab.permissionMode != mode else { return }
            tab.permissionMode = mode
        }
        .onChange(of: headlessSession?.model) { _, model in
            guard let model, tab.model != model else { return }
            tab.model = model
            // The conversation reported this, so it is a snapshot again: a
            // resume should let the conversation restore it rather than pin it.
            tab.isModelUserChosen = false
        }
        .onChange(of: headlessSession?.effort) { _, effort in
            guard let effort, tab.effort != effort else { return }
            tab.effort = effort
        }
        .onChange(of: planFilePath) { _, newPath in
            if newPath == nil { planPresentation = .hidden(.closed) }
        }
        // A proposal presents itself rather than waiting to be opened.
        // Interrupting a read is fine: the overlay minimizes to a dock bar,
        // so dismissing it costs one click and keeps the plan reachable.
        .onChange(of: pendingPlan?.id) { _, id in
            guard id != nil else { return }
            settledPlan = nil
            planPresentation = .expanded
        }
        // `initial` so a tab returned to mid-proposal finds its way back to a
        // dock bar. The state is per-view and starts closed, and without this
        // an approval that was already pending when the view went away never
        // changes again — the plan would be reachable only from the
        // composer's plan button, with no sign one was waiting.
        .onChange(of: planApproval, initial: true) { _, approval in
            planPresentation = planPresentation.reconciled(with: approval)
        }
        .onChange(of: headlessSession?.sessionID, initial: true) { _, sessionID in
            persistHeadlessSessionID(sessionID)
        }
        .overlay {
            if planPresentation.isExpanded, let planFilePath {
                planPanel(path: planFilePath)
                    // The bar is the source whenever it exists, so the panel
                    // grows out of it; opened straight from the Plan button
                    // there is none, and the effect is a no-op.
                    .matchedGeometryEffect(id: Self.planZoomID, in: planZoom, isSource: false)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let openSubagent {
                SubagentTranscriptOverlay(subagent: openSubagent, glass: planGlass) {
                    openSubagentID = nil
                }
                .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
                .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: planPresentation)
        .animation(.snappy(duration: 0.22), value: openSubagentID)
        .sheet(isPresented: $resumeSheetShown) {
            if let path = task.workingDirectoryPath {
                ResumeSessionSheet(
                    workingDirectory: path,
                    repoPath: task.repoPath,
                    onSelect: resume
                )
            }
        }
    }

    /// The floating bottom chrome: any queued messages, waiting their turn
    /// over the conversation, above the glass panel that holds the plan bar,
    /// composer and statusline.
    ///
    /// Measured together with `onGeometryChange`, whose action runs outside
    /// `body`, so the height reaches the list without a write during a
    /// render pass. Nothing inside this subtree reads `panelHeight`, which
    /// is what keeps the measurement from feeding back into itself.
    private func bottomChrome(transcript: Transcript) -> some View {
        VStack(spacing: dimensions.panelContentInset) {
            RemoteControlToast(tabID: tab.id)
                .listItemPadding(vertical: false)
            if let headlessSession, !headlessSession.queuedMessages.isEmpty {
                queuedMessagesView(headlessSession)
            }
            composerPanel(transcript: transcript)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
    }

    /// Each queued message is a message the user already wrote, waiting its
    /// turn — floated at the same content column as the composer panel below
    /// it, rather than the transcript's wider bleed column a sent bubble
    /// sits in. Sharing the panel's edge instead of a sent message's is part
    /// of what says "not sent yet".
    private func queuedMessagesView(_ session: any AgentSession) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(session.queuedMessages.enumerated()), id: \.offset) { index, message in
                QueuedMessageChip(
                    text: message,
                    onEdit: { editQueuedMessageIndex = index },
                    onRemove: { session.removeQueuedMessage(at: index) }
                )
            }
        }
        .listItemPadding(vertical: false)
    }

    /// The bottom chrome as one floating panel, content width like the prose
    /// above it: the plan dock bar when a plan is docked, then the composer,
    /// then the session facts under it. One glass surface carries all three.
    /// A closed plan's own button lives in the composer's controls row
    /// instead of up here — see `ComposerControlsRow.showsPlanButton`.
    private func composerPanel(transcript: Transcript) -> some View {
        let isDocked = planPresentation.hiddenForm == .dockBar
        return VStack(spacing: 0) {
            if let planFilePath, isDocked {
                planDockBar(path: planFilePath)
                    .transition(.opacity)
                Divider()
            }
            ChatComposer(
                task: task,
                tab: tab,
                isVisible: isVisible,
                hasContentAbove: isDocked,
                editQueuedMessageIndex: $editQueuedMessageIndex,
                showsPlanButton: planFilePath != nil && planPresentation.hiddenForm == .closed,
                onOpenPlan: { planPresentation = .expanded }
            )
            Divider()
            statuslineFooter(transcript: transcript)
        }
        .glassEffect(planGlass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
        .listItemPadding(vertical: false)
        .padding(.bottom, dimensions.panelInset)
    }

    /// Session-wide facts, below the composer rather than above it: what the
    /// conversation has spent reads as a footnote to the message being
    /// written rather than as a heading over it.
    ///
    /// It reads left to right as where this runs, then what it has spent,
    /// then whether anyone else can drive it.
    ///
    /// One `ViewThatFits` governs the whole row, because the branch name and
    /// the meters are the two things that give way and they have to give way
    /// in a fixed order. Three candidates, widest first:
    ///
    /// 1. Everything at its natural size, with the slack between the branch
    ///    name and the meters.
    /// 2. The branch name takes the leftover and truncates, down to
    ///    `statuslineBranchMinWidth`; the meters stay side by side.
    /// 3. The meters drop to bars alone, stacked.
    ///
    /// Nothing above this may be `.fixedSize()` horizontally: an unbounded
    /// width proposal makes the first candidate fit forever. Vertically it
    /// must be, or the row stretches to whatever height the chat leaves it.
    private func statuslineFooter(transcript: Transcript) -> some View {
        ViewThatFits(in: .horizontal) {
            statuslineRow(transcript: transcript, branchWidth: .natural, meters: .wide)
            statuslineRow(transcript: transcript, branchWidth: .flexible, meters: .wide)
            statuslineRow(transcript: transcript, branchWidth: .flexible, meters: .stacked)
        }
        .fixedSize(horizontal: false, vertical: true)
        // The one leading edge the composer's text and controls also sit on.
        .padding(.horizontal, dimensions.composerFieldInset)
        .padding(.vertical, dimensions.statuslineVerticalPadding)
    }

    /// One candidate of the row: where this runs on the leading edge, the
    /// meters and Remote Control on the trailing one.
    private func statuslineRow(
        transcript: Transcript,
        branchWidth: BranchWidth,
        meters: StatuslineStripLayout
    ) -> some View {
        HStack(alignment: .top, spacing: dimensions.panelContentInset) {
            workspaceGroup(branchWidth: branchWidth)
            // In every candidate, not just the widest: without it a row
            // narrower than the panel centers, holding the folder off the
            // leading edge and Remote Control off the trailing one. Its
            // `minLength` is fixed, so it still reports honest overflow.
            Spacer(minLength: dimensions.panelContentInset)
            HStack(alignment: .top, spacing: dimensions.statuslineTrailingGap) {
                StatuslineStripView(
                    layout: meters,
                    // Both arrive on a turn result, so a resumed conversation has
                    // neither until it takes a turn: the transcript's last usage
                    // and the tab's stored window cover that gap.
                    // contextMaxTokens falls back further still, to the model's
                    // nominal window — known before either does.
                    contextUsedTokens: headlessSession?.contextUsedTokens
                        ?? transcript.latestUsage?.contextUsedTokens,
                    contextMaxTokens: headlessSession?.contextWindow
                        ?? tab.contextWindowTokens
                        ?? headlessSession?.nominalContextWindow
                        ?? tab.model?.nominalContextWindow,
                    rateLimit: headlessSession?.rateLimit,
                    sessionCostUSD: headlessSession.flatMap { $0.sessionCostUSD > 0 ? $0.sessionCostUSD : nil }
                )
                if let headlessSession {
                    RemoteControlControl(session: headlessSession)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Where this runs: the folder, the worktree, and that worktree's own
    /// ahead/behind and dirty markers. Editable only until an agent starts,
    /// which fixes the working directory.
    private func workspaceGroup(branchWidth: BranchWidth) -> some View {
        WorkspacePickerView(
            task: task,
            isEditable: SurfaceManager.shared.existingSession(for: tab.id) == nil && headlessSession == nil,
            branchWidth: branchWidth,
            state: GitStateStore.shared.state(for: gitDirectory)
        )
        .font(typography.caption.font)
        .accessibilityIdentifier(AccessibilityID.composerWorkspacePicker)
    }

    /// A wash of the chat's own surface, so the glass reads as the chat holding
    /// a document rather than a system panel floating over it. Nil leaves the
    /// glass untinted, which is still legible.
    private var planTint: Color? {
        ThemeChrome.background(for: colorScheme)?.opacity(0.5)
    }

    private func planPanel(path: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text((path as NSString).lastPathComponent)
                    .font(.headline)
                Spacer()
                hidePlanButton
            }
            .padding(12)
            Divider()
            MarkdownContentView(content: planFile.content)
            planFooter
        }
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .glassEffect(planGlass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
        .listItemPadding(bleed: true)
        .padding(.vertical, dimensions.panelInset)
    }

    /// One button for leaving the plan, whose form follows what leaving it
    /// does: a live proposal can only be tucked into the dock bar, anything
    /// else is dismissed outright.
    @ViewBuilder
    private var hidePlanButton: some View {
        let isDockingOnly = planApproval == .awaitingDecision
        Button {
            planPresentation = .hidden(for: planApproval)
        } label: {
            Image(systemName: isDockingOnly ? "chevron.down" : "xmark.circle.fill")
                .emphasis(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(isDockingOnly ? "Minimize" : "Close")
        .accessibilityLabel(isDockingOnly ? "Minimize" : "Close")
        .accessibilityIdentifier(
            isDockingOnly ? AccessibilityID.planMinimizeButton : AccessibilityID.planCloseButton
        )
    }

    /// The approval options while a proposal is live, and where the plan
    /// landed otherwise. Held to content width and given room above, so the
    /// controls read as a decision rather than as more of the document.
    @ViewBuilder
    private var planFooter: some View {
        Divider()
        Group {
            if planApproval.showsApprovalOptions {
                planApprovalOptions
            } else if let label = planApproval.footerLabel {
                Text(label)
                    .font(typography.caption.font)
                    .emphasis(.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .chatTextColumn()
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
    }

    /// Feedback and the two decisions, right-aligned with Approve last —
    /// the primary option sits where the eye lands.
    ///
    /// The field is the composer's own editor, so a note reads the same
    /// wherever it is typed and obeys `composerSendKey` through the one rule
    /// in `ComposerNSTextView.keyDown`. Approve therefore takes no
    /// `.defaultAction` shortcut: a default button answers Return from
    /// `performKeyEquivalent`, which runs before the key ever reaches the
    /// focused field. ⌥↩ is captioned because nothing else on screen reveals
    /// it, and it is the only way to reach approve-with-feedback.
    @ViewBuilder
    private var planApprovalOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: DecisionCard.nestedPadding) {
                feedbackField
                ReservedWidthButton(
                    title: PlanRejectionLabel.label(forReason: planRejectionReason),
                    labels: PlanRejectionLabel.allLabels
                ) {
                    answerPlan(.reject)
                }
                .accessibilityIdentifier(AccessibilityID.planRejectButton)
                Button("Approve") { answerPlan(.approve) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.planApproveButton)
            }
            Text("⌥↩ approves with this feedback")
                .font(typography.caption.font)
                .emphasis(.subtle)
        }
        .font(typography.caption.font)
    }

    private var feedbackField: some View {
        MarkdownComposerTextView(
            text: $planRejectionReason,
            placeholder: "Feedback (optional)",
            fontSize: CGFloat(settings.chatFontSize),
            isFocused: $planFeedbackFocused,
            sendKey: settings.composerSendKey,
            onSend: { answerPlan(.reject) },
            onOptionReturn: { answerPlan(.approveWithFeedback) }
        )
        // `NSTextView` already inset its first glyph, so the shared field's
        // padding has to give that back rather than add to it.
        .padding(.horizontal, -Self.composerLineFragmentPadding)
        .decisionField(isFilled: !planRejectionReason.isEmpty, colors: colors)
        .accessibilityIdentifier(AccessibilityID.planFeedbackField)
    }

    /// `NSTextView` draws its first glyph one line-fragment padding in from
    /// its frame, which the field's own padding has to account for.
    private static let composerLineFragmentPadding: CGFloat = 5

    private enum PlanDecision {
        case approve
        case reject
        /// Approve, and let the typed note steer the plan that comes back.
        case approveWithFeedback
    }

    /// Answers the live proposal and remembers where it landed, so the footer
    /// keeps saying so once the request is gone.
    private func answerPlan(_ decision: PlanDecision) {
        guard let session = headlessSession, let pendingPlan else { return }
        switch decision {
        case .approve:
            session.approvePlan(pendingPlan)
            settledPlan = .init(toolUseID: pendingPlan.id, decision: .approved)
        case .reject:
            session.resolve(
                pendingPlan,
                with: .deny(message: PlanResolution.denialMessage(reason: planRejectionReason))
            )
            settledPlan = .init(toolUseID: pendingPlan.id, decision: .rejected)
        case .approveWithFeedback:
            session.approvePlan(pendingPlan, feedback: planRejectionReason)
            settledPlan = .init(toolUseID: pendingPlan.id, decision: .approved)
        }
        planRejectionReason = ""
        planPresentation = .hidden(.closed)
    }

    private func planDockBar(path: String) -> some View {
        HStack(spacing: 8) {
            // The whole row expands, so the target is the bar rather than just
            // the chevron; close stays a sibling so it isn't a nested button.
            Button {
                planPresentation = .expanded
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .emphasis(.secondary)
                    if let title = planFile.content.flatMap(PlanSummary.title(of:)) {
                        Text(title)
                            .lineLimit(1)
                        // Same size as the title, so the bar is the same
                        // height with or without one and the conversation
                        // above it never shifts. It yields its width first.
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .emphasis(.secondary)
                            .layoutPriority(-1)
                    } else {
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .emphasis(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Expand the plan")
            .accessibilityLabel("Expand the plan")
            .accessibilityIdentifier(AccessibilityID.planExpandButton)
        }
        .font(.callout)
        // The one leading edge the composer's text and the statusline's
        // first segment also sit on.
        .padding(.horizontal, dimensions.composerFieldInset)
        .padding(.vertical, dimensions.panelContentInset)
        .matchedGeometryEffect(id: Self.planZoomID, in: planZoom)
    }

    /// One id: only one plan surface is ever on screen.
    private static let planZoomID = "plan"

    private var planGlass: Glass {
        planTint.map { Glass.regular.tint($0) } ?? .regular
    }

    /// The conversation itself. Reached with only an optimistic message too,
    /// so the session facts below it fall back to an empty transcript — there
    /// is nothing on disk to read them from yet.
    private func conversationView(messages: [ChatMessage]) -> some View {
        let transcript = transcript ?? Transcript()
        return ChatMessageList(
            messages: messages,
            subagents: subagents,
            status: status,
            bottomPadding: dimensions.listBottomPadding,
            floatingPanelHeight: panelHeight,
            tabID: tab.id,
            onOpenSubagent: { openSubagentID = $0.id }
        )
        .overlay(alignment: .bottom) { bottomChrome(transcript: transcript) }
    }

    /// The composer stays mounted once a session exists, disabled rather than
    /// removed: dropping it left a gap between sending the first message and
    /// the first line of transcript arriving.
    private func emptyState(isComposerEnabled: Bool) -> some View {
        CenteredScrollView {
            emptyStateContent(isComposerEnabled: isComposerEnabled)
        }
        // The composer sits outside the scroll, as it does over a
        // conversation. Taken as a safe area rather than an overlay so the
        // scroll view shortens by the same amount it insets — an overlay plus
        // padding makes the content taller than the viewport by the
        // composer's height, and the screen then scrolls with room to spare.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            emptyStateComposer(isComposerEnabled: isComposerEnabled)
        }
    }

    private func emptyStateComposer(isComposerEnabled: Bool) -> some View {
        GlassEffectContainer {
            // The composer alone: the session facts don't exist yet, and
            // where this runs has been hoisted above as the decision the
            // empty state is actually about.
            ChatComposer(
                task: task,
                tab: tab,
                isVisible: isVisible,
                onLaunch: { pendingFirstMessage = OptimisticFirstMessage(text: $0) }
            )
            .disabled(!isComposerEnabled)
            .glassEffect(planGlass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
            .listItemPadding(vertical: false)
            .padding(.bottom, dimensions.panelInset)
        }
    }

    private func emptyStateContent(isComposerEnabled: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            // The composer's own column, so the sentence is as wide as the
            // panel below it and shares its leading edge rather than running
            // the width of the pane.
            VStack(alignment: .leading, spacing: dimensions.inlineClauseSpacing) {
                // Sized by the sentence's own font, like the folder and
                // worktree marks below it.
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(typography.headline.font)
                    .imageScale(.large)
                    .emphasis(.secondary)
                if isComposerEnabled {
                    workspaceChoice
                } else {
                    Text("Waiting for the first message…")
                        .font(.title2)
                        .emphasis(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, dimensions.composerFieldInset)
            .listItemPadding(vertical: false)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the agent will run, written as the empty state's own sentence
    /// rather than as a statusline chip. Before the first message this is the
    /// decision the screen is about, and the statusline drops its copy for
    /// that reason — see `emptyState`.
    private var workspaceChoice: some View {
        WorkspacePickerView(
            task: task,
            isEditable: true,
            branchWidth: .natural,
            prominence: .inline,
            state: GitStateStore.shared.state(for: gitDirectory),
            // Only before the first message: once a session exists, the tab
            // has the conversation it is going to have.
            resumeAction: canResume ? { resumeSheetShown = true } : nil
        )
        .font(typography.headline.font)
        .emphasis(.primary)
        .accessibilityIdentifier(AccessibilityID.composerWorkspacePicker)
    }

    /// Shown instead of the composer when `AgentLauncher` refused to spawn
    /// because Claude Code has not been told to trust this directory. The
    /// headless transport can't surface the real folder-trust prompt, so the
    /// fix is a terminal tab, where it can be answered — never granting the
    /// trust on the user's behalf.
    private func untrustedDirectoryState(path: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .emphasis(.secondary)
            Text("This directory isn't trusted")
                .font(.headline)
            Text("Claude Code needs to ask about \((path as NSString).lastPathComponent) before it can run there, and this chat can't show that prompt.")
                .font(.callout)
                .emphasis(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Open Terminal Tab") {
                TaskStore.addTab(to: task, kind: .terminal, in: modelContext)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the headless process died before writing any transcript, so
    /// there is no conversation to put a notice inside. The reason is the
    /// process's own last stderr line, which is the only account of what
    /// happened.
    private func startFailureState(_ failure: ChatStartFailure) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .emphasis(.secondary)
            Text(failure.title)
                .font(.headline)
            if let detail = failure.detail {
                ChatNoticeRow(notice: ChatNotice(kind: .error, title: detail, detail: nil))
                    .frame(maxWidth: 420)
            }
            if failure.remedy == .installCLI {
                Text("Plume runs `claude` through your login shell. Install Claude Code, or make sure it's on the PATH your shell profile sets.")
                    .font(.callout)
                    .emphasis(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 12) {
                Button("Try Again", action: retryAfterStartFailure)
                    .buttonStyle(.borderedProminent)
                Button("Open Terminal Tab") {
                    TaskStore.addTab(to: task, kind: .terminal, in: modelContext)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Drops the dead session so the tab returns to its empty state, ready to
    /// launch again on the next message. The PATH probe is re-run because
    /// installing the CLI is the fix this offers.
    private func retryAfterStartFailure() {
        ClaudeCLILocator.invalidate()
        HeadlessSessionManager.shared.closeSession(for: tab.id)
        StatusEngine.shared.setStatus(.notStarted, taskID: task.id, tabID: tab.id)
    }

    /// The terminal transport gets both watches from `MainWindow`'s hook
    /// callback; headless has no hooks, so this is the only place a headless
    /// tab's transcript path is known and both watches must start here.
    private func registerWatchIfNeeded() {
        guard let path = tab.sessionJSONLPath, !path.isEmpty else { return }
        TranscriptStore.shared.watch(tabID: tab.id, transcriptPath: path)
        AgentTitleMonitor.shared.watch(tabID: tab.id, transcriptPath: path)
    }

    /// Storing the ID is the whole resume: both transports watch
    /// `tab.agentSessionID` and launch `claude --resume` from it.
    private func resume(_ session: StoredSession) {
        tab.agentSessionID = session.sessionID
        tab.sessionJSONLPath = session.transcriptPath
    }

    /// The TUI path learns these from hook events; headless has no hooks, so
    /// the stream's own `session_id` is the only source. Persisted so resume
    /// survives an app restart and so the chat has a transcript to read.
    private func persistHeadlessSessionID(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty, tab.agentSessionID != sessionID else { return }
        tab.agentSessionID = sessionID
        guard let workingDirectory = task.workingDirectoryPath else { return }
        tab.sessionJSONLPath = SessionJSONLReader.resolvedTranscriptPath(
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
    }

}

/// One queued message, styled like the user bubble it's about to become.
/// Edit and remove are always visible rather than hover-revealed: reserving
/// their width while they're invisible most of the time reads as a layout
/// bug, and always showing them costs nothing here since a chip only ever
/// holds two small icon buttons.
private struct QueuedMessageChip: View, ThemedView {
    @Environment(\.theme) var theme

    let text: String
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        // `.firstTextBaseline` rather than `.top`: the clock glyph and the
        // edit/remove icons are a different font size than the message text,
        // so top-aligning their frames left the clock sitting visibly above
        // the text's first line. Baseline alignment tracks that first line
        // instead, which also reads right once the text wraps to several.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock")
                .font(typography.caption.font)
                .emphasis(.secondary)
                .help("Queued — not sent yet")
            Text(text)
                .font(typography.body.font)
                .lineSpacing(typography.body.lineSpacing)
                .lineLimit(1 ... 4)
                .fixedSize(horizontal: false, vertical: true)
            controls
        }
        .padding(10)
        .glassEffect(Glass.regular.tint(washColor), in: .rect(cornerRadius: 10))
        .frame(maxWidth: dimensions.contentWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button(action: onEdit) {
                Image(systemName: "pencil.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
    }

    /// `surfaceTint` is foreground at 10-15% opacity already (`EmphasisScale`),
    /// so it tints the glass without a further cut the way `planTint` needs
    /// on its near-opaque source.
    private var washColor: Color {
        colors.surfaceTint
    }
}
