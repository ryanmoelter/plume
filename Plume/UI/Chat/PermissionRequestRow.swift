import SwiftUI

/// One ordinary tool call waiting on approval — Bash, Write, Edit and the
/// rest, whose request carries no structured interactive payload.
///
/// The agent stalls until this is answered, so the row states what will run
/// and offers Allow, or Deny with a reason the model receives as the tool
/// result.
struct PermissionRequestRow: View, ThemedView {
    @Environment(\.theme) var theme

    let permission: PendingPermission
    let allow: () -> Void
    let deny: (String) -> Void

    @State private var denialReason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let description = permission.description, !description.isEmpty {
                Text(description)
                    .font(typography.caption.font)
                    .textSelection(.enabled)
                    .chatTextColumn()
            }
            if let reason = permission.decisionReason, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(typography.caption.font)
                    .foregroundStyle(colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .chatTextColumn()
            }
            inputFields
            TextField("Reason (optional, sent on deny)", text: $denialReason)
                .textFieldStyle(.roundedBorder)
                .font(typography.caption.font)
            HStack(spacing: 8) {
                Button("Allow", action: allow)
                    .keyboardShortcut(.defaultAction)
                Button("Deny") { deny(denialReason) }
                Spacer()
            }
            .font(typography.caption.font)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(washColor, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(colors.warning.emphasized(.disabled, in: colors), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(permission.displayName, systemImage: "hand.raised")
                .font(typography.caption.semibold)
                .foregroundStyle(colors.warning)
            if permission.agentID != nil {
                Label("subagent", systemImage: "person.2")
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
        }
    }

    @ViewBuilder
    private var inputFields: some View {
        let fields = PermissionInputDetails.fields(for: permission.input)
        if !fields.isEmpty {
            // Bounded, so a whole file body scrolls in place instead of
            // pushing the buttons off screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fields) { field in
                        fieldRow(field)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: PermissionInputDetails.Field) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.key)
                .font(typography.caption.font)
                .emphasis(.subtle)
                .chatTextColumn()
            if field.isCode {
                Text(field.value)
                    .font(typography.caption.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(field.value)
                    .font(typography.caption.font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chatTextColumn()
            }
        }
    }

    private var washColor: Color {
        colors.surfaceTint
    }
}
