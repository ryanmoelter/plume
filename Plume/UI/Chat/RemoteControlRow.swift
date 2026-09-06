import AppKit
import SwiftUI

/// What Remote Control is doing, docked below the conversation.
///
/// One row that updates in place rather than a log: the bridge is a single
/// live thing, and its state lives on `HeadlessSession`, which outlives the
/// view. `/rc` produces no transcript line of its own — the CLI handles the
/// command itself — so without this the chat looks identical whether the
/// command worked or did nothing at all.
struct RemoteControlRow: View, ThemedView {
    @Environment(\.theme) var theme

    let tabID: UUID

    var body: some View {
        if let session = HeadlessSessionManager.shared.existingSession(for: tabID),
           session.remoteControl != .disconnected {
            content(for: session.remoteControl)
                .font(typography.caption.font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
                .listItemPadding(vertical: false)
                .accessibilityIdentifier(AccessibilityID.remoteControlRow)
        }
    }

    @ViewBuilder
    private func content(for state: RemoteControlState) -> some View {
        switch state {
        case .disconnected:
            EmptyView()
        case .connecting:
            label("Connecting to Remote Control…", symbol: "antenna.radiowaves.left.and.right")
                .emphasis(.secondary)
        case .connected(let link):
            VStack(alignment: .leading, spacing: 6) {
                label("Remote Control is on", symbol: "antenna.radiowaves.left.and.right")
                if let url = link.shareableURL {
                    linkRow(url)
                }
                Text("This session keeps running here. Disconnect with /rc.")
                    .emphasis(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                label("Remote Control failed", symbol: "exclamationmark.triangle")
                Text(message)
                    .emphasis(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func label(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .imageScale(.small)
        }
    }

    private func linkRow(_ url: String) -> some View {
        HStack(spacing: 6) {
            Text(url)
                .font(typography.caption.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("Copy the link")
            .accessibilityLabel("Copy the Remote Control link")
            .accessibilityIdentifier(AccessibilityID.remoteControlCopyLinkButton)
        }
    }
}
