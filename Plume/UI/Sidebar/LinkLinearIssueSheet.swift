import SwiftUI

struct LinkLinearIssueSheet: View {
    let task: WorkTask
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var showsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link Linear Issue")
                .font(.headline)
            TextField("PLUME-123 or issue URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(link)
                .onChange(of: input) { _, _ in showsError = false }
                .plumeID(AccessibilityID.linkLinearIssueField)
            if showsError {
                Text("Not a Linear issue identifier")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Link", action: link)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    .plumeID(AccessibilityID.linkLinearIssueConfirmButton)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func link() {
        guard TaskStore.linkLinearIssue(input, to: task),
              let identifier = LinearIdentifier.normalize(input) else {
            showsError = true
            return
        }
        let teamKey = LinearIdentifier.teamKey(of: identifier)
        if !LinearStore.shared.teamKeys.contains(teamKey) {
            LinearStore.shared.refreshCatalogIfUnknown(teamKey: teamKey)
        }
        dismiss()
    }
}
