import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var helperState = CommandLineHelper.summary(of: CommandLineHelper.states())
    @State private var helperError: String?
    @State private var wtState = CommandLineHelper.wtSummary(of: CommandLineHelper.wtState())
    @State private var wtError: String?
    @State private var fullDiskAccessGranted = FullDiskAccess.isGranted
    @State private var plumeIsLinked = Self.isPlumeLinked()
    @State private var zshrcURL: URL?
    @State private var zshrcHasInitLine = false
    @State private var zshrcError: String?

    var body: some View {
        Form {
            Section {
                fullDiskAccessRow
                commandLineHelperRow
                wtLinkRow
                shellSetupRow
                KeepAwakeHelperRow()
            } header: {
                Text("Permissions + helpers")
            }

            Section {
                Toggle("Confirm before quitting while an agent is working", isOn: $settings.confirmQuitWhileWorking)
                Toggle("Also confirm on logout, restart, or shutdown", isOn: $settings.confirmSystemInitiatedQuit)
            } header: {
                Text("Quit confirmation")
            }

            Section {
                Toggle("Notify when an agent needs you, like for a question or a permission", isOn: $settings.notifiesWhenNeeded)
                Toggle("Notify when an agent finishes its turn", isOn: $settings.notifiesOnTurnEnd)
            } header: {
                Text("Notifications")
            }

            Section {
                HStack {
                    TextField("Worktree base path", text: worktreeBasePathBinding, prompt: Text(".plume/worktrees/"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button("Choose…", action: chooseBasePath)
                    if settings.worktreeBasePath != nil {
                        Button("Reset") { settings.worktreeBasePath = nil }
                    }
                }
            } header: {
                Text("Worktree base path")
            }

            Section {
                LabeledContent("Import from cmux") {
                    Button("Import…", systemImage: "square.and.arrow.down") { requestImport(.cmux) }
                        .plumeID(AccessibilityID.settingsImportCmuxButton, invoke: { requestImport(.cmux) })
                }
                LabeledContent("Import from Orca") {
                    Button("Import…", systemImage: "square.and.arrow.down") { requestImport(.orca) }
                        .plumeID(AccessibilityID.settingsImportOrcaButton, invoke: { requestImport(.orca) })
                }
                LabeledContent("Import from Claude desktop app") {
                    Button("Import…", systemImage: "square.and.arrow.down") { requestImport(.claudeDesktop) }
                        .plumeID(AccessibilityID.settingsImportClaudeDesktopButton, invoke: { requestImport(.claudeDesktop) })
                }
            } header: {
                Text("Import")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            helperState = CommandLineHelper.summary(of: CommandLineHelper.states())
            wtState = CommandLineHelper.wtSummary(of: CommandLineHelper.wtState())
            fullDiskAccessGranted = FullDiskAccess.isGranted
            plumeIsLinked = Self.isPlumeLinked()
        }
        .task {
            let (url, added) = await Task.detached {
                let url = ZshrcSetup.resolveZshrcURL()
                return (url, ZshrcSetup.isAdded(to: url))
            }.value
            zshrcURL = url
            zshrcHasInitLine = added
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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

    private var commandLineHelperRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                ForEach(helperState.statusLines, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let installTitle = helperState.installTitle {
                        Button(installTitle) { changeHelperInstall { try CommandLineHelper.install() } }
                    }
                    if helperState.canRemove {
                        Button("Remove") { changeHelperInstall { try CommandLineHelper.uninstall() } }
                    }
                }
                if let helperError {
                    Text(helperError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Command line tool")
            Text("Links `plume` into `~/.local/bin`, plus `plume-notify` for older scripts")
                .foregroundStyle(.secondary)
        }
    }

    private var wtLinkRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Text(wtState.status)
                    .foregroundStyle(.secondary)
                    .plumeID(AccessibilityID.settingsWTLinkStatus, value: wtState.status)
                HStack {
                    if let installTitle = wtState.installTitle {
                        Button(installTitle) { changeWTLink { try CommandLineHelper.installWT() } }
                            .plumeID(AccessibilityID.settingsWTLinkButton, invoke: { changeWTLink { try CommandLineHelper.installWT() } })
                    }
                    if wtState.canRemove {
                        Button("Remove") { changeWTLink { try CommandLineHelper.uninstallWT() } }
                            .plumeID(AccessibilityID.settingsWTUnlinkButton, invoke: { changeWTLink { try CommandLineHelper.uninstallWT() } })
                    }
                }
                if let wtError {
                    Text(wtError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("`wt` command")
            Text("Also links `wt` into `~/.local/bin`, running `plume wt`")
                .foregroundStyle(.secondary)
        }
    }

    private var shellSetupRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Text(ZshrcSetup.initLine)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy", action: copyInitLine)
                        .plumeID(AccessibilityID.settingsShellSetupCopyButton, invoke: copyInitLine)
                    if zshrcHasInitLine {
                        Text("Added")
                            .foregroundStyle(.secondary)
                            .plumeID(AccessibilityID.settingsShellSetupStatus, value: "Added")
                    } else {
                        Button("Add to .zshrc", action: addInitLine)
                            .plumeID(AccessibilityID.settingsShellSetupAddButton, invoke: addInitLine)
                            .disabled(!plumeIsLinked || zshrcURL == nil)
                    }
                }
                if !plumeIsLinked {
                    Text("Install the command line tool first")
                        .foregroundStyle(.secondary)
                        .plumeID(AccessibilityID.settingsShellSetupStatus, value: "Install the command line tool first")
                } else if let zshrcURL, !zshrcHasInitLine {
                    Text("Appends to \((zshrcURL.path as NSString).abbreviatingWithTildeInPath)")
                        .foregroundStyle(.secondary)
                }
                if let zshrcError {
                    Text(zshrcError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Shell integration")
            Text("Completions, `wt`, and a `wt switch` that changes directory")
                .foregroundStyle(.secondary)
        }
    }

    /// The init line calls `plume` by name, so it needs a `plume` on PATH:
    /// this bundle's link, or another Plume's, works.
    private static func isPlumeLinked() -> Bool {
        switch CommandLineHelper.states().first(where: { $0.name == "plume" })?.state {
        case .installed, .outdated, .ownedByOtherPlume: true
        case .notInstalled, .occupiedByOther, .brokenLink, nil: false
        }
    }

    private func copyInitLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ZshrcSetup.initLine, forType: .string)
    }

    private func addInitLine() {
        guard let zshrcURL, plumeIsLinked else { return }
        zshrcError = nil
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try ZshrcSetup.add(to: zshrcURL)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            zshrcError = error
            zshrcHasInitLine = error == nil
        }
    }

    private func changeWTLink(_ change: () throws -> Void) {
        wtError = nil
        do {
            try change()
        } catch {
            wtError = error.localizedDescription
        }
        wtState = CommandLineHelper.wtSummary(of: CommandLineHelper.wtState())
    }

    private func requestImport(_ source: ImportSource) {
        if !ImportRequest.shared.request(source) { NSSound.beep() }
    }

    private func changeHelperInstall(_ change: () throws -> Void) {
        helperError = nil
        do {
            try change()
        } catch {
            helperError = error.localizedDescription
        }
        helperState = CommandLineHelper.summary(of: CommandLineHelper.states())
        plumeIsLinked = Self.isPlumeLinked()
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
