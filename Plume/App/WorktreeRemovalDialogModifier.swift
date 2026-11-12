import SwiftUI

/// The confirmation dialog plus its error alert, shared by the delete and
/// archive flows. Its own `ViewModifier` so `MainWindow.body` attaches it
/// with one `.modifier(_:)` rather than inlining another dialog/alert pair,
/// which the type checker cannot finish in reasonable time alongside
/// everything else already in that view.
struct WorktreeRemovalDialogModifier: ViewModifier {
    @Binding var pendingRemoval: WorktreeRemovalPrompt.PendingRemoval?
    @Binding var removalError: String?
    let onConfirm: (WorktreeRemovalPrompt.PendingRemoval, Bool, Bool) -> Void

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
                Button(removal.primaryButtonTitle, role: .destructive) {
                    onConfirm(removal, true, false)
                }
                Button(removal.withBranchButtonTitle, role: .destructive) {
                    onConfirm(removal, true, true)
                }
                Button(removal.taskOnlyButtonTitle) {
                    onConfirm(removal, false, false)
                }
                Button("Cancel", role: .cancel) {}
            } message: { removal in
                Text(removal.message)
            }
            .alert("Could Not Remove Worktree", isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )) {
                Button("OK") { removalError = nil }
            } message: {
                Text(removalError ?? "")
            }
    }
}
