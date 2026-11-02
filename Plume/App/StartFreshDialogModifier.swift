import SwiftUI

/// Confirms dropping a tab's link to its previous conversation. Its own
/// `ViewModifier` for the same reason as `LiveAgentRemovalDialogModifier`:
/// inlined in `MainWindow.body`, it tips a Release build's type checker past
/// its time budget.
struct StartFreshDialogModifier: ViewModifier {
    @Binding var pendingTab: TaskTab?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Start a fresh conversation?",
                isPresented: Binding(
                    get: { pendingTab != nil },
                    set: { if !$0 { pendingTab = nil } }
                ),
                presenting: pendingTab
            ) { tab in
                Button("Start Fresh", role: .destructive) {
                    TaskStore.startFresh(tab)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This discards \(AppIdentity.displayName)'s link to the previous conversation. The transcript stays on disk, but \(AppIdentity.displayName) won't be able to resume it.")
            }
    }
}
