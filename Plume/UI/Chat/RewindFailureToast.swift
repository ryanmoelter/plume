import SwiftUI

/// Why a redo did not happen, floated above the composer until dismissed.
///
/// Most refusals are timing rather than breakage — `turn_running` and
/// `prompt_pending` both mean "not right now" — so this says what to do and
/// waits, rather than disappearing on a timer the user may not be looking at.
///
/// Sits beside `RemoteControlToast` and shares its chrome: both report a live
/// property of the session, which is not something that happened at a point in
/// the transcript and so is not a chat row.
struct RewindFailureToast: View, ThemedView {
    @Environment(\.theme) var theme

    let tabID: UUID

    var body: some View {
        if let session = AgentSessionManager.shared.existingSession(for: tabID) as? HeadlessSession,
           let failure = session.rewindFailure {
            Button { session.dismissRewindFailure() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                    Text(failure)
                        .lineLimit(2)
                }
                .font(typography.caption.font)
                .foregroundStyle(colors.danger)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(Glass.regular.tint(colors.surfaceTint), in: .capsule)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .transition(.opacity)
            // The text as the value, since it is SwiftUI's own and a driver
            // cannot read it as AppKit text.
            .plumeID(AccessibilityID.rewindFailureToast, value: failure)
        }
    }
}
