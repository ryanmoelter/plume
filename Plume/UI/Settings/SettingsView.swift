import AppKit
import ServiceManagement
import SwiftUI

/// The app's `Settings` scene (⌘,). A stub in v1: a worktree base path
/// override, read by `WorkspaceProvisioner`, and a provider field, read by
/// `AgentLauncher` via `AgentProviderRegistry`.
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var cliRefresh = 0
    #if DEBUG
    @State private var revealTuning = RevealTuning.shared
    #endif
    @State private var keepAwake = KeepAwakeCoordinator.shared
    @State private var updates = UpdateController.shared
    @State private var newIgnoredCheckName = ""
    @State private var helperState = CommandLineHelper.state()
    @State private var helperError: String?
    @State private var fullDiskAccessGranted = FullDiskAccess.isGranted

    private var displayedProviders: Set<AgentProviderKind>? {
        AgentCLIAvailability.shared.providers.map { AgentCLIInstallation.displayedProviders($0) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Default (inside each repo)", text: worktreeBasePathBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseBasePath)
                    if settings.worktreeBasePath != nil {
                        Button("Reset") { settings.worktreeBasePath = nil }
                    }
                }
            } header: {
                Text("Worktree Base Path")
            } footer: {
                Text("New worktrees are created here instead of inside the repository's .plume/worktrees folder.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New agent tabs run", selection: $settings.defaultProvider) {
                    ForEach(AgentProviderKind.allCases) { provider in
                        Label {
                            Text(provider == .codex ? "Codex (Beta)" : provider.displayName)
                        } icon: {
                            AgentProviderIcon(provider: provider)
                        }
                        .tag(provider)
                    }
                }
            } footer: {
                Text("A tab records the CLI it was created with, so changing this never moves an existing conversation. Codex support is in beta; tested with Codex CLI 0.153.4.")
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            AgentInstallationDebugSection()
            #endif

            if let installedProviders = displayedProviders, installedProviders.count < AgentProviderKind.allCases.count {
                Section("Install agents") {
                    ForEach(AgentProviderKind.allCases.filter { !installedProviders.contains($0) }) { provider in
                        Link(destination: AgentCLIInstallation.downloadURL(for: provider)) {
                            Label {
                                Text(AgentCLIInstallation.downloadTitle(for: provider))
                            } icon: {
                                AgentProviderIcon(provider: provider)
                            }
                        }
                        .plumeID("settings-install-cli", label: provider.rawValue)
                    }
                }
            }

            Section {
                Picker("New agent tabs use", selection: $settings.defaultAgentTransport) {
                    Text("Headless").tag(AgentTransport.headless)
                    Text("Terminal (TUI)").tag(AgentTransport.terminal)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Agent Transport")
            } footer: {
                Text("Headless drives the selected agent directly and can answer permission prompts and questions from the chat. Terminal keeps the CLI's PTY-backed interface as a fallback.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.defaultProvider == .claudeCode {
                    Picker("New agent tabs start in", selection: $settings.defaultPermissionMode) {
                        ForEach(PermissionModeDefault.offered(showsBypassPermissions: settings.showsBypassPermissions)) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                } else {
                    Picker("New agent tabs start in", selection: $settings.defaultCodexPermissionProfileRaw) {
                        ForEach(AgentPermissionPreset.offeredCodexProfiles(AgentPermissionPreset.codexPresets, showsFullAccess: settings.showsBypassPermissions)) { profile in
                            Text(profile.label).tag(profile.id)
                        }
                    }
                }
                Toggle("Show Bypass Permissions / Full Access", isOn: $settings.showsBypassPermissions)
            } header: {
                Text("Default Permissions")
            } footer: {
                Text(settings.defaultProvider == .claudeCode
                    ? "Follow Claude Code reads permissions.defaultMode from ~/.claude/settings.json."
                    : "Codex permission profiles control filesystem and network access for new threads.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New agent tabs think at", selection: $settings.defaultEffort) {
                    ForEach(settings.defaultProvider.efforts) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
            } header: {
                Text("Default Effort")
            } footer: {
                Text("A tab's own effort, set from its chat, overrides this. Available levels follow the selected provider.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Slider(
                        value: $settings.chatFontSize,
                        in: AppSettings.chatFontSizeRange,
                        step: 1
                    )
                    Text("\(Int(settings.chatFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Code size")
                    Slider(
                        value: $settings.codeFontSizeMultiplier,
                        in: AppSettings.codeFontSizeMultiplierRange,
                        step: 0.05
                    )
                    Text("\(Int(settings.codeFontSizeMultiplier * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Picker("Send message with", selection: $settings.composerSendKey) {
                    Text("⌘Return").tag(ComposerSendKey.commandReturn)
                    Text("Return").tag(ComposerSendKey.returnKey)
                }
            } header: {
                Text("Chat")
            } footer: {
                Text(
                    "Text size sets the prose size in the chat view — messages, tool calls, " +
                    "and thinking blocks scale together. Code size adjusts the code font on " +
                    "top of that, to match x-heights between the two faces. The other key " +
                    "inserts a newline instead of sending, so a half-typed multi-line message " +
                    "stays editable."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Animate chat message motion", isOn: $settings.animateChatMotion)
                Toggle("Fade streamed text in as it arrives", isOn: $settings.animateCharacterReveal)
            } header: {
                Text("Chat Animation")
            } footer: {
                Text(
                    "Message motion eases a message that grows or collapses into its new size, " +
                    "grows a newly arrived one into place, and slides the conversation when the " +
                    "composer changes height. The reveal fades streamed text in a word at a time, " +
                    "on a spring that speeds up the further it falls behind the text received."
                )
                .foregroundStyle(.secondary)
            }

            #if DEBUG
            Section {
                RevealSlider(
                    title: "Response",
                    value: $revealTuning.values.response,
                    range: RevealTuning.responseRange,
                    step: 0.05,
                    format: { String(format: "%.2fs", $0) }
                )
                RevealSlider(
                    title: "Damping",
                    value: $revealTuning.values.dampingRatio,
                    range: RevealTuning.dampingRatioRange,
                    step: 0.05,
                    format: { String(format: "%.2f", $0) }
                )
                RevealSlider(
                    title: "Minimum speed",
                    value: $revealTuning.values.minimumSpeed,
                    range: RevealTuning.minimumSpeedRange,
                    step: 1,
                    format: { "\(Int($0))/s" }
                )
                RevealSlider(
                    title: "Maximum speed",
                    value: $revealTuning.values.maximumSpeed,
                    range: RevealTuning.maximumSpeedRange,
                    step: 10,
                    format: { $0 == 0 ? "Off" : "\(Int($0))/s" }
                )
                RevealSlider(
                    title: "Word fade time",
                    value: $revealTuning.values.fadeDuration,
                    range: RevealTuning.fadeDurationRange,
                    step: 0.05,
                    format: { $0 == 0 ? "Instant" : String(format: "%.2fs", $0) }
                )
                RevealSlider(
                    title: "Frame rate",
                    value: $revealTuning.values.frameRate,
                    range: RevealTuning.frameRateRange,
                    step: 10,
                    format: { "\(Int($0)) fps" }
                )
                Button("Reset to Defaults") { revealTuning.reset() }
                    .disabled(revealTuning.values == .defaults)
            } header: {
                Text("Reveal Tuning")
            } footer: {
                Text(
                    "The reveal is a character index on a spring pulled toward the newest " +
                    "character. Response is the spring's period: lower chases the text harder. " +
                    "Damping 1 settles without overshoot; lower surges. Speeds are characters " +
                    "per second. Each word fades in over the fade time from the moment the " +
                    "reveal reaches it, so a long word holds the next one back for longer."
                )
                .foregroundStyle(.secondary)
            }
            #endif

            Section {
                Toggle("Notify when an agent finishes its turn", isOn: $settings.notifiesOnTurnEnd)
            } header: {
                Text("Notifications")
            } footer: {
                Text(
                    "An agent that needs an answer — a plan to approve, a question, " +
                    "a tool waiting on permission — always notifies, and says which. " +
                    "A finished turn is quieter and far more frequent, so it is off " +
                    "by default."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .plumeID(
                        AccessibilityID.updatesAutoCheckToggle,
                        value: String(updates.automaticallyChecksForUpdates),
                        setValue: { updates.automaticallyChecksForUpdates = ($0 == "true" || $0 == "1") }
                    )

                HStack {
                    Button("Check Now", action: updates.checkForUpdates)
                        .plumeID(AccessibilityID.updatesCheckNowButton)
                        .disabled(!updates.canCheckForUpdates)
                    Spacer()
                }

                if updates.isHomebrewInstall || settings.updateInstallSourceOverride != nil {
                    Picker("Install updates with", selection: installSourceBinding) {
                        ForEach(UpdateInstallSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .plumeID(
                        AccessibilityID.updatesInstallSourcePicker,
                        value: updates.installSource.rawValue,
                        setValue: { if let source = UpdateInstallSource(rawValue: $0) { installSourceBinding.wrappedValue = source } }
                    )
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updatesFooterText)
                    .foregroundStyle(.secondary)
            }
            .disabled(!updates.isRunning)

            Section {
                HStack {
                    Text(helperStatusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(helperButtonTitle, action: toggleHelperInstall)
                }
                if let helperError {
                    Text(helperError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Command Line")
            } footer: {
                Text(
                    "Installs plume-notify into ~/.local/bin, as a link into the app bundle. " +
                    "Run `plume-notify \"Build finished\" \"12 tests passed\"` from any terminal " +
                    "or agent tab and the notification routes back to that tab."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep the Mac awake", selection: $settings.keepAwakeMode) {
                    ForEach(KeepAwakeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Keep awake for Remote Control", isOn: $settings.keepsAwakeForRemoteControl)
                Toggle("Keep awake on battery", isOn: $settings.keepsAwakeOnBattery)
                if settings.keepsAwakeOnBattery {
                    Stepper(
                        batteryCutoffLabel,
                        value: $settings.keepAwakeBatteryCutoffPercent,
                        in: 0...100,
                        step: 5
                    )
                }
                Toggle("Keep awake with the lid closed", isOn: $settings.keepsAwakeWithLidClosed)
                    .plumeID(
                        AccessibilityID.keepAwakeLidToggle,
                        value: String(settings.keepsAwakeWithLidClosed),
                        setValue: { settings.keepsAwakeWithLidClosed = ($0 == "true" || $0 == "1") }
                    )
                    .disabled(!keepAwake.lidOverrideStatus.canEngage)
                sleepHelperRow
                if settings.keepsAwakeWithLidClosed {
                    LabeledContent("Allow sleep when temperature is") {
                        ThermalCutoffMenu(selection: $settings.lidClosedThermalCutoff)
                    }
                }
            } header: {
                Text("Keep Awake")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Auto holds the Mac awake while an agent is working, and while a " +
                        "session is under remote control unless that is turned off. On " +
                        "battery the hold stops at the cutoff unless charging. Closing " +
                        "the lid sleeps the Mac unless the sleep helper is installed and " +
                        "approved in Login Items, and even then the lid override releases " +
                        "at the chosen temperature."
                    )
                    .foregroundStyle(.secondary)
                    Button("Open Battery Settings…") {
                        SystemSettingsLink.battery.open()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.label) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(shortcut: settings.shortcutBindings[action]) { shortcut in
                                settings.shortcutBindings.assign(shortcut, to: action)
                            }
                            .frame(width: 120, height: 22)
                            .plumeID(
                                AccessibilityID.shortcutRecorder,
                                label: action.label,
                                value: settings.shortcutBindings[action]?.displayName ?? "Unassigned",
                                setValue: { chord in
                                    guard let shortcut = MenuShortcut(displayName: chord) else { return }
                                    settings.shortcutBindings.assign(shortcut, to: action)
                                }
                            )

                            Button {
                                settings.shortcutBindings.reset(action)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!settings.shortcutBindings.isCustomized(action))
                            .plumeID(AccessibilityID.shortcutResetButton, label: action.label)
                        }
                    }
                }

                Button("Reset All") { settings.shortcutBindings.resetAll() }
                    .plumeID(AccessibilityID.shortcutResetAllButton)
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text(
                    "Click a shortcut, then press the chord you want. Assigning a chord that " +
                    "another command here already uses leaves that command unassigned, since two " +
                    "menu items sharing a chord leaves macOS to pick one. Command and Option " +
                    "chords are taken back from a focused terminal; an Option chord you bind " +
                    "stops reaching the shell inside that terminal."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Confirm before quitting while an agent is working", isOn: $settings.confirmQuitWhileWorking)
                Toggle("Also confirm on logout, restart, or shutdown", isOn: $settings.confirmSystemInitiatedQuit)
            } header: {
                Text("Quit Confirmation")
            } footer: {
                Text(
                    "Quitting always ends running agent processes immediately. " +
                    "Confirming during a logout, restart, or shutdown blocks that " +
                    "shutdown until someone dismisses the prompt, so leave it off " +
                    "unless you want that."
                )
                .foregroundStyle(.secondary)
            }
            Section {
                fullDiskAccessRow
            } header: {
                Text("Permissions")
            } footer: {
                Text("A change here applies after \(AppIdentity.displayName) restarts.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show GitHub PR status in the sidebar", isOn: $settings.showsPullRequestStatus)

                ForEach(settings.ignoredPendingChecks, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            settings.ignoredPendingChecks.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Check name", text: $newIgnoredCheckName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIgnoredCheck)
                    Button("Add", action: addIgnoredCheck)
                        .disabled(newIgnoredCheckName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Integrations")
            } footer: {
                Text(
                    "Names a check whose PENDING state \(AppIdentity.displayName) ignores while folding a PR's CI " +
                    "result — a real pass or fail from it still counts, only a check stuck " +
                    "pending forever stops masking the rest. Matching is an exact, " +
                    "case-sensitive name; a mismatch silently won't apply. The repository's " +
                    "own ryanmoelter-cli-tools.ignoredPendingChecks git config adds to this " +
                    "list rather than replacing it."
                )
                .foregroundStyle(.secondary)
            }
        }
        .task(id: cliRefresh) {
            await AgentCLIAvailability.shared.refresh()
        }
        .onChange(of: displayedProviders, initial: true) { _, installed in
            if let installed { settings.reconcileInstalledProviders(installed) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .onAppear {
            helperState = CommandLineHelper.state()
            keepAwake.refreshLidOverride()
            fullDiskAccessGranted = FullDiskAccess.isGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cliRefresh += 1
            fullDiskAccessGranted = FullDiskAccess.isGranted
        }
    }

    @ViewBuilder
    private var fullDiskAccessRow: some View {
        LabeledContent("Full Disk Access") {
            Text(fullDiskAccessGranted ? "Granted" : "Not granted")
                .foregroundStyle(fullDiskAccessGranted ? Color.secondary : Color.orange)
                .plumeID(AccessibilityID.fullDiskAccessStatus, value: fullDiskAccessGranted ? "Granted" : "Not granted")
            Button("Open System Settings…") {
                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
            }
            .plumeID(AccessibilityID.fullDiskAccessManageButton)
        }
    }

    @ViewBuilder
    private var sleepHelperRow: some View {
        switch keepAwake.lidOverrideStatus {
        case .notRegistered:
            LabeledContent("Sleep helper") {
                Button("Install…") { keepAwake.installLidHelper() }
                    .plumeID(AccessibilityID.keepAwakeLidInstallButton)
            }
        case .needsApproval:
            LabeledContent("Sleep helper") {
                Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .plumeID(AccessibilityID.keepAwakeLidApprovalButton)
            }
        case .unavailable(let reason):
            LabeledContent("Sleep helper") {
                Text(reason).foregroundStyle(.red)
            }
        case .ready, .engaged:
            LabeledContent("Sleep helper") {
                HStack {
                    Text("Installed").foregroundStyle(.secondary)
                    Button("Uninstall") { keepAwake.uninstallLidHelper() }
                        .plumeID(AccessibilityID.keepAwakeLidUninstallButton)
                }
            }
        }
    }

    private var batteryCutoffLabel: String {
        settings.keepAwakeBatteryCutoffPercent == 0
            ? "No battery cutoff"
            : "Allow sleep below \(settings.keepAwakeBatteryCutoffPercent)%"
    }

    /// Explicit rather than following `updates.installSource`: choosing a
    /// value here always sets the override, even when it matches what
    /// detection would already have picked.
    private var installSourceBinding: Binding<UpdateInstallSource> {
        Binding(
            get: { updates.installSource },
            set: { settings.updateInstallSourceOverride = $0 }
        )
    }

    private var updatesFooterText: String {
        guard updates.isRunning else {
            return "Updates are off in debug builds."
        }
        let lastChecked = updates.lastUpdateCheckDate.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
            ?? "Never checked."
        guard updates.isHomebrewInstall || settings.updateInstallSourceOverride != nil else {
            return lastChecked
        }
        return lastChecked + " A Homebrew install updates with brew upgrade rather than in place."
    }

    private var helperStatusText: String {
        switch helperState {
        case .installed: "Installed at \(CommandLineHelper.installedURL.path)"
        case .notInstalled: "Not installed"
        case .occupiedByOther: "Another file owns that name"
        case .brokenLink: "Installed, but pointing at a bundle that is gone"
        }
    }

    private var helperButtonTitle: String {
        if case .installed = helperState { "Remove" } else { "Install" }
    }

    private func toggleHelperInstall() {
        helperError = nil
        do {
            if case .installed = helperState {
                try CommandLineHelper.uninstall()
            } else {
                try CommandLineHelper.install()
            }
        } catch {
            helperError = error.localizedDescription
        }
        helperState = CommandLineHelper.state()
    }

    private func addIgnoredCheck() {
        let trimmed = newIgnoredCheckName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.ignoredPendingChecks.append(trimmed)
        newIgnoredCheckName = ""
    }

    private var worktreeBasePathBinding: Binding<String> {
        Binding(
            get: { settings.worktreeBasePath ?? "" },
            set: { settings.worktreeBasePath = $0.isEmpty ? nil : $0 }
        )
    }

    private func chooseBasePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.worktreeBasePath = url.path
    }
}

/// One reveal parameter: a label, a slider, and the value it is set to.
private struct RevealSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
