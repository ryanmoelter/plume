import AppKit
import SwiftUI

/// Remote Control as the info pane shows it, from either CLI.
enum RemoteControlStatus: Equatable {
    case off, connecting, on, failed(String)

    init(claude state: RemoteControlState) {
        switch state {
        case .disconnected: self = .off
        case .connecting: self = .connecting
        case .connected: self = .on
        case .failed(let error): self = .failed(error)
        }
    }

    init(codex remote: CodexRemoteControl) {
        // Pairing/device-management failures do not turn off a live host.
        if remote.status == .connected {
            self = .on
        } else if remote.status == .connecting || remote.operation == .enabling {
            self = .connecting
        } else if let error = remote.operationError {
            self = .failed(error)
        } else if remote.status == .errored {
            self = .failed("Codex could not establish remote access")
        } else {
            self = .off
        }
    }

    /// Nil for a session that has no Remote Control at all.
    init?(session: any AgentSession) {
        if let codex = session as? CodexSession {
            self.init(codex: codex.effectiveRemoteControl)
        } else if let claude = session as? HeadlessSession {
            self.init(claude: claude.remoteControl)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .off: "Remote control is off"
        case .connecting: "Remote control is connecting…"
        case .on: "Remote control is on"
        case .failed: "Remote control failed"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting"
        case .on: "On"
        case .failed(let message): "Failed: \(message)"
        }
    }

    var symbol: String {
        switch self {
        case .on, .connecting: StatusSymbol.remoteControl.name
        case .off, .failed: "\(StatusSymbol.remoteControl.name).slash"
        }
    }
}

/// The info pane's Remote Control row, driving the same `setRemoteControl`
/// the typed `/rc` does.
struct RemoteControlRow: View, ThemedView {
    @Environment(\.theme) var theme
    let session: any AgentSession
    @State private var showsCodexDetails = false
    @State private var isHoveringMenu = false

    private var codexRemote: CodexRemoteControl? {
        (session as? CodexSession)?.effectiveRemoteControl
    }

    private var status: RemoteControlStatus { RemoteControlStatus(session: session) ?? .off }

    private var isEnabled: Bool {
        if let remote = codexRemote { return remote.isAvailableForRemoteAccess }
        switch status {
        case .on, .connecting: return true
        case .off, .failed: return false
        }
    }

    var body: some View {
        HStack(spacing: InfoPaneLayout.columnSpacing) {
            InfoPaneIcon { Image(systemName: status.symbol) }
                .foregroundStyle(tint)
            Text(status.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            menu
        }
        .emphasis(.secondary)
        .padding(.vertical, InfoPaneLayout.rowVerticalPadding)
        .help(helpText)
        .sheet(isPresented: $showsCodexDetails) {
            if let remote = codexRemote { CodexRemoteControlPanel(remote: remote) }
        }
    }

    private var menu: some View {
        Menu {
            Button(isEnabled ? "Disconnect Remote Control" : "Connect Remote Control", action: toggle)
                .disabled(codexRemote?.operation == .disabling)
            if codexRemote != nil {
                Button("Pair and Manage Devices…") { showsCodexDetails = true }
            } else if let claude = session as? HeadlessSession,
                      case .connected(let link) = claude.remoteControl,
                      let url = link.shareableURL {
                Button("Copy Remote Control Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(colors.selection)
        .frame(width: InfoPaneLayout.iconColumnWidth)
        .modifier(OverlaidControlWash(isHovering: isHoveringMenu))
        .plumeHover { isHoveringMenu = $0 }
        .accessibilityLabel("Remote Control")
        .accessibilityValue(status.accessibilityValue)
        .plumeID(AccessibilityID.infoPaneRemoteControlMenu, value: status.accessibilityValue,
                 invoke: codexRemote == nil ? nil : { showsCodexDetails = true })
    }

    private func toggle() {
        let enabled = !isEnabled
        if let remote = codexRemote {
            if enabled { showsCodexDetails = true }
            Task { await remote.setEnabled(enabled) }
        } else if let claude = session as? HeadlessSession {
            claude.setRemoteControl(enabled: enabled)
        }
    }

    private var tint: Color {
        switch status {
        case .on: colors.attention
        case .failed: colors.danger
        case .connecting, .off: colors.foreground.opacity(colors.emphasis[.secondary])
        }
    }

    private var helpText: String {
        switch status {
        case .on:
            codexRemote != nil
                ? "Remote Control is on — manage this Codex host and paired devices"
                : "Remote Control is on — this session is on claude.ai/code"
        case .connecting: "Connecting to Remote Control…"
        case .failed(let message): "Remote Control failed: \(message)"
        case .off:
            codexRemote != nil
                ? "Remote Control — pair a device with this Codex host"
                : "Remote Control — drive this session from your phone or claude.ai/code"
        }
    }
}
