import SwiftUI

/// Every request the headless session is waiting on, stacked in arrival
/// order. Parallel tool calls mean there can be several at once, and each
/// stalls its own call until answered.
struct PendingPermissionDock: View {
    let tabID: UUID

    var body: some View {
        if let session = HeadlessSessionManager.shared.existingSession(for: tabID),
           !session.pendingPermissions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.pendingPermissions) { permission in
                    row(for: permission, in: session)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for permission: PendingPermission, in session: HeadlessSession) -> some View {
        if let interactive = permission.interactive {
            InteractiveToolRow(payload: interactive, isPending: true) { answer in
                switch answer {
                case .questions(let answers):
                    session.answer(permission, answers: answers)
                case .approvePlan:
                    session.approvePlan(permission)
                case .rejectPlan(let reason):
                    session.resolve(permission, with: .deny(message: denialMessage(reason)))
                }
            }
        } else {
            PermissionRequestRow(
                permission: permission,
                allow: { session.resolve(permission, with: .allow(updatedInput: permission.input)) },
                deny: { session.resolve(permission, with: .deny(message: denialMessage($0))) }
            )
        }
    }

    /// The model reads this as the tool result, so an empty field still needs
    /// to say something. Built through `PlanResolution` so its fixed prefix
    /// is how a settled transcript row later tells a rejection's result text
    /// apart from an approval's — the user's own reason is free text and
    /// can't be told apart from an approval message any other way.
    private func denialMessage(_ reason: String) -> String {
        PlanResolution.denialMessage(reason: reason)
    }
}
