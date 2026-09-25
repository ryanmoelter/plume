import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var helperState = CommandLineHelper.state()
    @State private var helperError: String?
    @State private var fullDiskAccessGranted = FullDiskAccess.isGranted

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
                Text("By default, a new worktree goes in the repository's .plume/worktrees folder.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when an agent finishes its turn", isOn: $settings.notifiesOnTurnEnd)
            } header: {
                Text("Notifications")
            } footer: {
                Text("An agent that needs your answer always notifies you.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Confirm before quitting while an agent is working", isOn: $settings.confirmQuitWhileWorking)
                Toggle("Also confirm on logout, restart, or shutdown", isOn: $settings.confirmSystemInitiatedQuit)
            } header: {
                Text("Quit Confirmation")
            } footer: {
                Text("Quitting stops every running agent. A confirmation on logout, restart, or shutdown holds the Mac until you answer it.")
                    .foregroundStyle(.secondary)
            }

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
                Text("Links plume-notify into ~/.local/bin. Run `plume-notify \"Build finished\"` in any tab to post a notification from that tab.")
                    .foregroundStyle(.secondary)
            }

            Section {
                fullDiskAccessRow
            } header: {
                Text("Permissions")
            } footer: {
                Text("Restart \(AppIdentity.displayName) after you change this.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            helperState = CommandLineHelper.state()
            fullDiskAccessGranted = FullDiskAccess.isGranted
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
