import SwiftUI

/// One line for a note another session sent this one: "↳ fix-login finished
/// a turn: Tests pass". Clicking it selects that session's tab; the note's
/// full text stays out of the chat, since the model already has it.
struct SideSessionEventRow: View, ThemedView {
    @Environment(\.theme) var theme

    let event: SideSessionEvent

    var body: some View {
        Button(action: select) {
            Label {
                Text(event.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: InjectedContent.sideSessionEvent(event).markerSymbol)
                    .imageScale(.small)
            }
            .font(typography.caption.font)
            .emphasis(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(event.sessionID == nil ? "" : "Show this session")
        .plumeID(
            AccessibilityID.sideSessionEventRow,
            label: event.displayName ?? event.summary,
            value: event.summary,
            invoke: select
        )
        .disabled(event.sessionID == nil)
        .listItemPadding(vertical: false)
    }

    private func select() {
        guard let sessionID = event.sessionID else { return }
        ChildSessionCoordinator.shared.select(sessionID: sessionID)
    }
}
