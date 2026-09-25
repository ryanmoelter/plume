import SwiftUI

struct IntegrationsSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var newIgnoredCheckName = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show PR status in the sidebar", isOn: $settings.showsPullRequestStatus)
            } header: {
                Text("GitHub")
            }

            Section {
                ForEach(settings.ignoredPendingChecks, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            settings.ignoredPendingChecks.removeAll { $0 == name }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Ignored pending check name(s)", text: $newIgnoredCheckName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addIgnoredCheck)
                    Button("Add", action: addIgnoredCheck)
                        .disabled(newIgnoredCheckName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                GitConfigIgnoredChecksRow()
            } header: {
                Text("Ignored pending checks")
            } footer: {
                Text("These checks don't count towards a pending state, e.g. if they're waiting for approval to run. They only count if they're a pass or fail.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addIgnoredCheck() {
        let trimmed = newIgnoredCheckName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.ignoredPendingChecks.append(trimmed)
        newIgnoredCheckName = ""
    }
}
