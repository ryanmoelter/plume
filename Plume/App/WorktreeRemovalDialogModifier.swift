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
                if removal.offersRemoval {
                    Button(removal.primaryButtonTitle, role: .destructive) {
                        onConfirm(removal, true, false)
                    }
                }
                if removal.offersBranchRemoval {
                    Button(removal.withBranchButtonTitle, role: .destructive) {
                        onConfirm(removal, true, true)
                    }
                }
                Button(removal.taskOnlyButtonTitle) {
                    onConfirm(removal, false, false)
                }
                Button("Cancel", role: .cancel) {}
            } message: { removal in
                Text(removal.message)
            }
            .modifier(WorktreeRemovalControls(pendingRemoval: $pendingRemoval, onConfirm: onConfirm))
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

/// The dialog's choices for the control server. A `confirmationDialog` is
/// an AppKit sheet, where no `plumeID` registers, so each choice registers
/// on the window instead while the dialog is up.
private struct WorktreeRemovalControls: ViewModifier {
    @Binding var pendingRemoval: WorktreeRemovalPrompt.PendingRemoval?
    let onConfirm: (WorktreeRemovalPrompt.PendingRemoval, Bool, Bool) -> Void

    func body(content: Content) -> some View {
        let removal = pendingRemoval
        let label = removal?.dialogTitle
        return content
            .plumeMenuItem(AccessibilityID.worktreeRemovalRemoveButton, label: label, isPresent: removal?.offersRemoval == true) {
                removal.map { onConfirm($0, true, false) }
            }
            .plumeMenuItem(
                AccessibilityID.worktreeRemovalWithBranchButton, label: label, isPresent: removal?.offersBranchRemoval == true
            ) {
                removal.map { onConfirm($0, true, true) }
            }
            .plumeMenuItem(AccessibilityID.worktreeRemovalTaskOnlyButton, label: label, isPresent: removal != nil) {
                removal.map { onConfirm($0, false, false) }
            }
            .plumeMenuItem(AccessibilityID.worktreeRemovalCancelButton, label: label, isPresent: removal != nil) {
                pendingRemoval = nil
            }
            .background {
                if let removal {
                    Color.clear.plumeID(AccessibilityID.worktreeRemovalMessage, label: removal.dialogTitle, value: removal.message)
                }
            }
    }
}
