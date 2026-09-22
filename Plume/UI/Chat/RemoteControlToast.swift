import AppKit
import SwiftUI

/// What Remote Control just did, floated briefly above the composer.
///
/// Not a chat row: the chat renders conversation history, and a bridge is a
/// live property of the session rather than something that happened at a
/// point in the transcript. It also sits outside the message list, so it
/// never grows that list's content.
///
/// The notice it renders lives on `HeadlessSession`, which outlives this
/// view — held here, both the text and its timer would die on a task switch
/// and start over on the way back.
struct RemoteControlToast: View, ThemedView {
    @Environment(\.theme) var theme

    let tabID: UUID

    var body: some View {
        if let session = HeadlessSessionManager.shared.existingSession(for: tabID),
           let notice = session.remoteControlNotice {
            Button {
                copyLink(for: notice, in: session)
            } label: {
                content(for: notice)
            }
            .buttonStyle(.plain)
            .disabled(notice.link?.shareableURL == nil)
            .help(helpText(for: notice))
            .transition(.opacity)
            .plumeID(AccessibilityID.remoteControlToast)
        }
    }

    private func content(for notice: RemoteControlState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(for: notice))
                .imageScale(.small)
            Text(title(for: notice))
                .lineLimit(1)
            if let detail = detail(for: notice) {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .emphasis(.secondary)
            }
        }
        .font(typography.caption.font)
        .foregroundStyle(tint(for: notice))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Glass, like the queued chips beside it: the toast floats over the
        // conversation, and a flat fill is hard to read against it.
        .glassEffect(Glass.regular.tint(colors.surfaceTint), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyLink(for notice: RemoteControlState, in session: HeadlessSession) {
        guard let url = notice.link?.shareableURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        session.dismissRemoteControlNotice()
    }

    private func symbol(for notice: RemoteControlState) -> String {
        switch notice {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func title(for notice: RemoteControlState) -> String {
        switch notice {
        case .connected: return "Remote Control is on"
        case .connecting: return "Connecting…"
        case .disconnected: return "Remote Control is off"
        case .failed: return "Remote Control failed"
        }
    }

    private func detail(for notice: RemoteControlState) -> String? {
        switch notice {
        case .connected(let link): return link.shareableURL
        case .failed(let message): return message
        case .connecting, .disconnected: return nil
        }
    }

    private func helpText(for notice: RemoteControlState) -> String {
        notice.link?.shareableURL == nil ? "" : "Copy the link"
    }

    private func tint(for notice: RemoteControlState) -> Color {
        switch notice {
        case .failed: return colors.danger
        case .connected, .connecting: return colors.attention
        case .disconnected: return colors.foreground
        }
    }
}
