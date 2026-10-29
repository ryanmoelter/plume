import SwiftUI

/// Settings ▸ Integrations ▸ Android Device Streaming: the `android` tool, its account and project.
struct RemoteDevicesSettingsSection: View {
    @State private var catalog = RemoteDeviceCatalog.shared
    @State private var isSigningOut = false

    var body: some View {
        Section {
            switch catalog.availability {
            case .loading:
                ProgressView().controlSize(.small)
            case .cliMissing:
                LabeledContent {
                    Link(destination: AndroidCLI.installURL) {
                        HStack(spacing: 4) {
                            Text("Install")
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    .buttonStyle(.bordered)
                    .plumeID(AccessibilityID.remoteDevicesInstallLink)
                } label: {
                    Text("android command-line tool")
                    Text("Not found. Install it to reserve devices from Google's lab.")
                        .foregroundStyle(.secondary)
                }
            case .signedOut:
                LabeledContent {
                    Button("Sign In…", action: signIn)
                        .plumeID(AccessibilityID.remoteDevicesSignInButton, invoke: signIn)
                } label: {
                    Text("Account")
                    Text("Not signed in. Signing in opens a terminal task in Plume.")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                LabeledContent {
                    Button("Sign In…", action: signIn)
                        .plumeID(AccessibilityID.remoteDevicesSignInButton, invoke: signIn)
                } label: {
                    Text("Account")
                    Text(message).foregroundStyle(.secondary)
                }
            case .projectsFailed(let account, let message):
                accountRow(account)
                LabeledContent {
                    Button("Refresh", action: refresh)
                        .plumeID(AccessibilityID.remoteDevicesProjectsRefreshButton, invoke: refresh)
                } label: {
                    Text("Project")
                    Text(message).foregroundStyle(.secondary)
                }
            case .signedIn(let account):
                accountRow(account)
                projectRow
            }
            if let path = catalog.cliPath {
                LabeledContent("Tool", value: path)
                    .font(.caption)
            }
        } header: {
            headerRow
        }
        .task { await catalog.loadIfNeeded() }
    }

    private func accountRow(_ account: String) -> some View {
        LabeledContent {
            Button("Sign Out", action: signOut)
                .plumeID(AccessibilityID.remoteDevicesSignOutButton, invoke: signOut)
                .disabled(isSigningOut)
        } label: {
            Text("Account")
            Text(account).foregroundStyle(.secondary)
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Android Device Streaming")
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check again")
            .plumeID(AccessibilityID.remoteDevicesRefreshButton, invoke: refresh)
        }
    }

    @ViewBuilder
    private var projectRow: some View {
        if catalog.projects.isEmpty {
            LabeledContent("Project") {
                Text("None is ready for streaming").foregroundStyle(.secondary)
            }
        } else {
            Picker("Project", selection: Binding(
                get: { catalog.selectedProject ?? "" },
                set: { catalog.selectedProject = $0 }
            )) {
                ForEach(catalog.projects, id: \.self) { Text($0).tag($0) }
            }
            .plumeID(AccessibilityID.remoteDevicesProjectPicker, value: catalog.selectedProject)
            .disabled(catalog.projects.count < 2)
        }
    }

    private func signIn() {
        catalog.signIn()
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await catalog.signOut()
            isSigningOut = false
        }
    }

    private func refresh() {
        Task { await catalog.load(refresh: true) }
    }
}
