import SwiftUI

/// Confirms a delete or archive that would stop a task's live agent. Its own
/// `ViewModifier` for the same reason as `WorktreeRemovalDialogModifier`:
/// inlining another dialog into `MainWindow.body` tips the type checker past
/// its time budget.
struct LiveAgentRemovalDialogModifier: ViewModifier {
    @Binding var pendingRemoval: PendingLiveAgentRemoval?
    let onConfirm: (WorkTask, WorktreeRemovalVerb) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingRemoval?.dialogTitle ?? "",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                presenting: pendingRemoval
            ) { removal in
                Button(removal.verb.title, role: .destructive) {
                    onConfirm(removal.task, removal.verb)
                }
                Button("Cancel", role: .cancel) {}
            } message: { removal in
                Text(removal.message)
            }
    }
}
