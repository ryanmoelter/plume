import SwiftUI

/// The chat rendering of an agent tab: the messages, then a floating panel
/// carrying the composer over the statusline strip, with the plan dock tucked
/// behind it when a plan is minimized.
struct ChatTabView: View, ThemedView {
    @Bindable var task: WorkTask
    let tab: TaskTab
    let isVisible: Bool

    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var settings = AppSettings.shared
    @State private var planPresentation = PlanPresentation.closed
    /// The last plan proposal the user answered here, so the footer can say
    /// where it landed once the live request is gone. Nil until they answer
    /// one in this tab — a plan approved before the app launched reads as
    /// "not approved yet" rather than claiming an approval we never saw.
    @State private var settledPlan: PlanApprovalState.Proposal?
    @State private var planRejectionReason = ""
    @State private var resumeSheetShown = false
    /// The subagent whose transcript is open over the chat, by id — held as an
    /// id rather than the value so the overlay follows the subagent's live
    /// re-reads instead of freezing at the moment it was opened.
    @State private var openSubagentID: String?
    @State private var untrustedDirectoryStore = UntrustedDirectoryStore.shared
    /// The dock bar and the expanded overlay are separate view trees, so the
    /// namespace the zoom between them matches on lives here, above both.
    @Namespace private var planZoom

    private var untrustedPath: String? {
        untrustedDirectoryStore.path(forTab: tab.id)
    }

    private var transcript: Transcript? {
        TranscriptStore.shared.transcript(forTab: tab.id)
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

    private var status: TaskStatus {
        StatusEngine.shared.status(forTab: tab.id)
    }

    private var headlessSession: HeadlessSession? {
        guard tab.transport == .headless else { return nil }
        return HeadlessSessionManager.shared.existingSession(for: tab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let transcript, !transcript.messages.isEmpty {
                ChatMessageList(
                    messages: transcript.messages,
                    subagents: subagents,
                    status: status,
                    bottomPadding: dimensions.listBottomPadding,
                    tabID: tab.id,
                    onOpenSubagent: { openSubagentID = $0.id }
                )
                composerPanel(transcript: transcript)
            } else if let untrustedPath {
                untrustedDirectoryState(path: untrustedPath)
            } else if SurfaceManager.shared.existingSession(for: tab.id) != nil
                || HeadlessSessionManager.shared.existingSession(for: tab.id) != nil
                || (tab.agentSessionID?.isEmpty == false) {
                // A process (or a resumable session) exists but has written no
                // transcript content yet — nothing to show but a quiet wait.
                emptyState(isComposerEnabled: false)
            } else {
                emptyState(isComposerEnabled: true)
            }
        }
        .background(ThemeChrome.background(for: colorScheme) ?? Color.clear)
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .onAppear { registerWatchIfNeeded() }
        .onChange(of: gitDirectory, initial: true) { previous, current in
            if let previous { GitStateStore.shared.release(previous) }
            if let current { GitStateStore.shared.watch(current) }
        }
        .onDisappear {
            if let gitDirectory { GitStateStore.shared.release(gitDirectory) }
        }
        .onChange(of: tab.sessionJSONLPath) { _, _ in registerWatchIfNeeded() }
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
            if newPath == nil { planPresentation = .closed }
        }
        // A proposal presents itself rather than waiting to be opened.
        // Interrupting a read is fine: the overlay minimizes to a dock bar,
        // so dismissing it costs one click and keeps the plan reachable.
        .onChange(of: pendingPlan?.id) { _, id in
            guard id != nil else { return }
            settledPlan = nil
            if planPresentation != .expanded { planPresentation = .expanded }
        }
        .onChange(of: headlessSession?.sessionID, initial: true) { _, sessionID in
            persistHeadlessSessionID(sessionID)
        }
        .overlay {
            if planPresentation == .expanded, let planFilePath {
                planPanel(path: planFilePath)
                    .matchedGeometryEffect(id: Self.planZoomID, in: planZoom)
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

    /// The bottom chrome as one floating panel: the composer, the session
    /// facts under it, and the plan bar tucked behind them when a plan is
    /// minimized.
    ///
    /// Grouped in one `GlassEffectContainer` so the dock bar and the surface
    /// below both glass-render as one panel: without it each gets its own
    /// backdrop sample and the dock's shadow paints onto the surface it's
    /// supposed to read as tucked behind.
    private func composerPanel(transcript: Transcript) -> some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                if planPresentation == .minimized, let planFilePath {
                    planDockBar(path: planFilePath)
                        .transition(.opacity)
                }
                VStack(spacing: 0) {
                    ChatComposer(task: task, tab: tab, isVisible: isVisible)
                    Divider()
                    statuslineFooter(transcript: transcript)
                }
                .glassEffect(planGlass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
            }
            .listItemPadding(bleed: true, vertical: false)
            .padding(.bottom, dimensions.panelInset)
        }
    }

    /// Session-wide facts, below the composer rather than above it: what the
    /// conversation has spent reads as a footnote to the message being
    /// written rather than as a heading over it.
    private func statuslineFooter(transcript: Transcript) -> some View {
        HStack(spacing: 0) {
            StatuslineStripView(
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
                branch: transcript.gitBranch,
                gitState: GitStateStore.shared.state(for: gitDirectory),
                rateLimit: headlessSession?.rateLimit,
                sessionCostUSD: headlessSession.flatMap { $0.sessionCostUSD > 0 ? $0.sessionCostUSD : nil }
            )
            if let planFilePath, planPresentation != .minimized {
                planButton(path: planFilePath)
            }
        }
        .padding(.horizontal, dimensions.panelContentInset)
    }

    private func planButton(path: String) -> some View {
        Button {
            planPresentation = .expanded
        } label: {
            Label("Plan", systemImage: "doc.text")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .emphasis(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
                Button {
                    planPresentation = .minimized
                } label: {
                    Image(systemName: "chevron.down")
                        .emphasis(.secondary)
                }
                .buttonStyle(.plain)
                .help("Minimize")
                .accessibilityLabel("Minimize")
                .accessibilityIdentifier(AccessibilityID.planMinimizeButton)
                Button {
                    planPresentation = .closed
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .emphasis(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
                .accessibilityIdentifier(AccessibilityID.planCloseButton)
            }
            .padding(12)
            Divider()
            MarkdownFileView(path: path)
            planFooter
        }
        .environment(\.chatFontSize, CGFloat(settings.chatFontSize))
        .plumeTheme(bodySize: CGFloat(settings.chatFontSize))
        .glassEffect(planGlass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
        .listItemPadding(bleed: true)
        .padding(.vertical, 8)
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
    /// the primary option sits where the eye lands and where Return goes.
    ///
    /// Feedback submits the rejection from inside the field, so typing and
    /// sending are one gesture rather than a field plus a distant button.
    /// ⌥↩ is captioned because nothing else on screen reveals it, and it is
    /// the only way to reach approve-with-feedback.
    @ViewBuilder
    private var planApprovalOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Feedback (optional)", text: $planRejectionReason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .font(typography.caption.font)
                    .onKeyPress(.return, phases: .down) { press in
                        handleFeedbackReturn(press.modifiers)
                    }
                    .accessibilityIdentifier(AccessibilityID.planFeedbackField)
                ReservedWidthButton(
                    title: PlanRejectionLabel.label(forReason: planRejectionReason),
                    labels: PlanRejectionLabel.allLabels
                ) {
                    answerPlan(.reject)
                }
                .accessibilityIdentifier(AccessibilityID.planRejectButton)
                Button("Approve") { answerPlan(.approve) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.planApproveButton)
            }
            Text("⌥↩ approves with this feedback")
                .font(typography.caption.font)
                .emphasis(.subtle)
        }
        .font(typography.caption.font)
    }

    /// Return in the feedback field follows `composerSendKey` exactly as the
    /// composer does; ⌥ always reaches the third option.
    private func handleFeedbackReturn(_ modifiers: EventModifiers) -> KeyPress.Result {
        let key = PlanFeedbackKey.forReturn(
            sendKey: settings.composerSendKey,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option)
        )
        switch key {
        case .submit:
            answerPlan(.reject)
            return .handled
        case .approveWithFeedback:
            answerPlan(.approveWithFeedback)
            return .handled
        case .passThrough:
            return .ignored
        }
    }

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
        planPresentation = .minimized
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
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
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

            Button {
                planPresentation = .closed
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier(AccessibilityID.planCloseButton)
        }
        .font(.callout)
        .padding(.horizontal, dimensions.composerFieldInset)
        .padding(.vertical, dimensions.panelContentInset)
        // Rounded like the panel on top and square where it meets it, so the
        // bar reads as tucked behind the panel rather than as a pill of its
        // own.
        .glassEffect(
            planGlass,
            in: .rect(
                topLeadingRadius: dimensions.panelCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: dimensions.panelCornerRadius
            )
        )
        .padding(.horizontal, ComposerPanelMetrics.tuckedInset(panelCornerRadius: dimensions.panelCornerRadius))
        .padding(.top, dimensions.panelInset)
        .matchedGeometryEffect(id: Self.planZoomID, in: planZoom)
    }

    /// One id: only one plan surface is ever on screen.
    private static let planZoomID = "plan"

    private var planGlass: Glass {
        planTint.map { Glass.regular.tint($0) } ?? .regular
    }

    /// The composer stays mounted once a session exists, disabled rather than
    /// removed: dropping it left a gap between sending the first message and
    /// the first line of transcript arriving.
    private func emptyState(isComposerEnabled: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .emphasis(.secondary)
            Text(isComposerEnabled ? "Start a conversation" : "Waiting for the first message…")
                .font(.headline)
                .emphasis(.secondary)
            // Only before the first message: once a session exists, the tab
            // has the conversation it is going to have.
            if isComposerEnabled, canResume {
                Button("Resume…") { resumeSheetShown = true }
                    .buttonStyle(.link)
                    .help("Continue a past Claude conversation in this folder")
            }
            Spacer()
            GlassEffectContainer {
                ChatComposer(task: task, tab: tab, isVisible: isVisible)
                    .disabled(!isComposerEnabled)
                    .glassEffect(planGlass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
                    .listItemPadding(bleed: true, vertical: false)
                    .padding(.bottom, dimensions.panelInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        tab.sessionJSONLPath = SessionJSONLReader.transcriptPath(
            workingDirectory: workingDirectory,
            sessionID: sessionID
        )
    }

}
