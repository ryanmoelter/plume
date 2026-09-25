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
                fullDiskAccessRow
                commandLineHelperRow
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
                    Button("Import…", action: requestImport)
                        .plumeID(AccessibilityID.settingsImportCmuxButton, invoke: requestImport)
                }
            } header: {
                Text("Import")
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

    private var commandLineHelperRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                HStack {
                    Text(helperStatusText)
                        .foregroundStyle(.secondary)
                    Button(helperButtonTitle, action: toggleHelperInstall)
                }
                if let helperError {
                    Text(helperError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Command line helper")
            Text("Currently just `plume-notify`, links into `~/.local/bin`")
                .foregroundStyle(.secondary)
        }
    }

    private func requestImport() {
        ImportRequest.shared.isPending = true
    }

    private var helperStatusText: String {
        switch helperState {
        case .installed: "Installed"
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
