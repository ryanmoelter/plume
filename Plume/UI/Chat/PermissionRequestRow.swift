import SwiftUI

/// One ordinary tool call waiting on approval — Bash, Write, Edit and the
/// rest, whose request carries no structured interactive payload.
///
/// The agent stalls until this is answered, so the row states what will run
/// and offers Allow, or Deny with a reason the model receives as the tool
/// result. Drawn as a `DecisionCard` like the question card beside it — the
/// accent hue is the only thing that says which of the two this is.
struct PermissionRequestRow: View, ThemedView {
    @Environment(\.theme) var theme

    let permission: PendingPermission
    let allow: () -> Void
    let deny: (String) -> Void

    @State private var denialReason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DecisionCard.sectionSpacing) {
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
            denialReasonField
            HStack(spacing: DecisionCard.nestedPadding) {
                Spacer()
                Button("Deny") { deny(denialReason) }
                Button("Allow", action: allow)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .font(typography.caption.font)
            .chatTextColumn()
        }
        .decisionCard(subject: .consequential, colors: colors)
    }

    private var header: some View {
        DecisionCardHeader(
            title: permission.displayName,
            symbol: StatusSymbol.permission.name,
            subject: .consequential,
            trailing: permission.agentID == nil
                ? nil
                : (text: "subagent", symbol: StatusSymbol.subagents.name)
        )
    }

    private var denialReasonField: some View {
        TextField("Reason (optional, sent on deny)", text: $denialReason, axis: .vertical)
            .textFieldStyle(.plain)
            .font(typography.body.medium)
            .decisionField(isFilled: !denialReason.isEmpty, colors: colors)
            .chatTextColumn()
            .accessibilityIdentifier(AccessibilityID.permissionDenialReasonField)
    }

    @ViewBuilder
    private var inputFields: some View {
        let fields = PermissionInputDetails.fields(for: permission.input)
        if !fields.isEmpty {
            // Bounded, so a whole file body scrolls in place instead of
            // pushing the buttons off screen.
            ScrollView {
                VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
                    ForEach(fields) { field in
                        fieldRow(field)
                    }
                }
                .padding(DecisionCard.nestedPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(colors.surfaceTint, in: .rect(cornerRadius: DecisionCard.nestedRadius))
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
}
