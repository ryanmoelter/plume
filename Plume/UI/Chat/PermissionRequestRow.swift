import SwiftUI

/// One ordinary tool call waiting on approval — Bash, Write, Edit and the
/// rest, whose request carries no structured interactive payload.
///
/// The agent stalls until this is answered, so the row states what will run
/// and offers Allow, or Deny with a reason the model receives as the tool
/// result.
struct PermissionRequestRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let permission: PendingPermission
    let allow: () -> Void
    let deny: (String) -> Void

    @State private var denialReason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let description = permission.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: chatFontSize * 0.85))
                    .textSelection(.enabled)
            }
            if let reason = permission.decisionReason, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: chatFontSize * 0.78))
                    .foregroundStyle(ChatRole.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            inputFields
            TextField("Reason (optional, sent on deny)", text: $denialReason)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: chatFontSize * 0.85))
            HStack(spacing: 8) {
                Button("Allow", action: allow)
                    .keyboardShortcut(.defaultAction)
                Button("Deny") { deny(denialReason) }
                Spacer()
            }
            .font(.system(size: chatFontSize * 0.85))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(washColor, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ChatRole.attention.emphasized(.disabled, colorScheme: colorScheme), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(permission.displayName, systemImage: "hand.raised")
                .font(.system(size: chatFontSize * 0.85, weight: .semibold))
                .foregroundStyle(ChatRole.attention)
            if permission.agentID != nil {
                Label("subagent", systemImage: "person.2")
                    .font(.system(size: chatFontSize * 0.7))
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.key)
                                .font(.system(size: chatFontSize * 0.7))
                                .emphasis(.subtle)
                            Text(field.value)
                                .font(.system(
                                    size: chatFontSize * 0.85,
                                    design: field.isCode ? .monospaced : .default
                                ))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(.chatSurface(.backgroundTint, colorScheme: colorScheme), in: .rect(cornerRadius: 6))
        }
    }

    private var washColor: Color {
        .chatSurface(.backgroundTint, colorScheme: colorScheme)
    }
}
