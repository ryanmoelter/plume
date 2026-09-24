import AppKit
import SwiftUI

/// Brief state-change notices, with failures retained until resolved. The
/// antenna carries steady state, so an enabled host needs no second banner.
struct CodexRemoteControlNotice: View, ThemedView {
    @Environment(\.theme) var theme
    let remote: CodexRemoteControl
    @State private var showsDetails = false
    @State private var transientStatus: CodexRemoteControl.Status?

    private var error: String? {
        remote.operationError ?? (remote.status == .errored ? "Codex could not establish remote access" : nil)
    }

    var body: some View {
        Group {
            if error != nil || transientStatus != nil {
                Button { showsDetails = true } label: {
                    RemoteControlToastContent(
                        symbol: error != nil ? "exclamationmark.triangle"
                            : transientStatus == .disabled ? "\(StatusSymbol.remoteControl.name).slash"
                            : StatusSymbol.remoteControl.name,
                        title: title,
                        detail: error,
                        tint: error != nil ? colors.danger
                            : transientStatus == .disabled ? colors.foreground : colors.attention
                    )
                }
                .buttonStyle(.plain)
                .help("Show Codex remote access and pairing details")
                .transition(.opacity)
                .plumeID(AccessibilityID.remoteControlToast, label: title, value: error)
            }
        }
        .sheet(isPresented: $showsDetails) { CodexRemoteControlPanel(remote: remote) }
        .onChange(of: remote.status) { _, status in
            transientStatus = status == .errored ? nil : status
        }
        .onChange(of: remote.operation) { _, operation in
            if operation == .enabling { transientStatus = .connecting }
        }
        .task(id: transientStatus) {
            guard transientStatus != nil else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            transientStatus = nil
        }
    }

    private var title: String {
        if error != nil { return "Remote Control failed" }
        switch transientStatus {
        case .connected: return "Remote Control is on"
        case .connecting: return "Connecting…"
        case .disabled: return "Remote Control is off"
        case .errored: return "Remote Control failed"
        case nil: return "Remote Control"
        }
    }
}

struct CodexRemoteControlPanel: View {
    let remote: CodexRemoteControl
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex Remote Control (Beta)").font(.headline)
            Text("Remote access applies to the Codex host, including its conversations and local tools. It is not limited to this chat.")
                .foregroundStyle(.secondary)
            Text("Remote access is shared by \(AppIdentity.displayName)’s connected Codex chat tabs. Terminal-mode tabs use separate servers. Closing one connected chat keeps the host available while another remains connected.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(statusText, systemImage: StatusSymbol.remoteControl.name)
                Spacer()
                if remote.operation != nil { ProgressView().controlSize(.small) }
                Button(remote.isAvailableForRemoteAccess ? "Disconnect" : "Connect") {
                    Task { await remote.setEnabled(!remote.isAvailableForRemoteAccess) }
                }
                .disabled(remote.operation == .disabling)
                .plumeID("codex-remote-toggle", label: remote.isAvailableForRemoteAccess ? "Disconnect" : "Connect", value: statusText)
            }
            if let error = remote.operationError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else if remote.status == .errored {
                Text("Codex could not establish remote access. Another Codex app may already be serving this host.")
                    .foregroundStyle(.red)
            }
            if remote.status == .connected {
                Divider()
                Text("Pair a device").font(.subheadline.bold())
                Text("Scan the QR code with your phone to open ChatGPT setup. Sign in with the same account and workspace.")
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let pairing = remote.pairing {
                        if remote.pairingClaimed {
                            Label("Device paired", systemImage: "checkmark.circle")
                        } else if pairing.expiresAt <= context.date {
                            Text("Pairing code expired. Generate a new code.").foregroundStyle(.secondary)
                        } else if let link = CodexPairingLink.url(code: pairing.pairingCode, expiresAt: pairing.expiresAt, now: context.date) {
                            HStack(alignment: .top, spacing: 14) {
                                CodexPairingQRCode(url: link)
                                VStack(alignment: .leading, spacing: 10) {
                                    Button("Copy Pairing Link") {
                                        guard let current = remote.pairing,
                                              let url = CodexPairingLink.url(code: current.pairingCode, expiresAt: current.expiresAt, claimed: remote.pairingClaimed) else { return }
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                    if let code = pairing.manualCode {
                                        Text("From another computer, open ChatGPT Settings > Connections > Control other devices, choose Add, and enter:")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(code).font(.title3.monospaced()).textSelection(.enabled)
                                        Button("Copy Code") {
                                            guard pairing.isUsable, !remote.pairingClaimed else { return }
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(code, forType: .string)
                                        }
                                    }
                                    Text("Expires \(pairing.expiresAt, style: .relative)").font(.caption)
                                }
                            }
                        }
                    }
                }
                Button(remote.pairing == nil ? "Generate Pairing Code" : "Generate New Code") {
                    Task { await remote.startPairing() }
                }
                .disabled(remote.isLoadingPairing || remote.operation != nil)
                .plumeID("codex-remote-generate-pairing", invoke: { Task { await remote.startPairing() } })
                Divider()
                HStack {
                    Text("Paired devices").font(.subheadline.bold())
                    Spacer()
                    Button("Refresh") { Task { await remote.refreshClients() } }
                        .disabled(remote.isLoadingClients || remote.clientsUnavailable)
                }
                if remote.clientsUnavailable {
                    Text("This Codex version cannot list paired devices. Manage devices in ChatGPT Settings > Connections > Control other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if remote.clients.isEmpty {
                    Text(remote.isLoadingClients ? "Loading devices…" : remote.hasLoadedClients ? "No paired devices." : "Paired devices could not be loaded.")
                        .foregroundStyle(.secondary)
                }
                if remote.revokeUnavailable {
                    Text("This Codex version cannot revoke device access. Manage devices in ChatGPT Settings > Connections > Control other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(remote.clients) { client in
                    HStack {
                        Text(client.displayName)
                        Spacer()
                        Button("Revoke Access", role: .destructive) { Task { await remote.revokeClient(client.id) } }
                            .disabled(remote.revokeUnavailable)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 470)
        .task {
            await remote.refresh()
            await remote.refreshClients()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await remote.refresh()
                await remote.refreshPairingStatus()
            }
        }
        .task(id: remote.status) {
            if remote.status == .connected { await remote.refreshClients() }
        }
        .onChange(of: remote.pairingClaimed) { _, claimed in
            if claimed { Task { await remote.refreshClients() } }
        }
    }

    private var statusText: String {
        switch remote.status {
        case .disabled: remote.operation == .enabling ? "Connecting…" : "Off"
        case .connecting: "Connecting…"
        case .connected: "On — \(remote.serverName ?? "Codex host")"
        case .errored: "Connection failed"
        }
    }
}
