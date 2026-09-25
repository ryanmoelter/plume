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
            } header: {
                Text("Ignored pending checks")
            } footer: {
                Text("While a check listed here is pending, it does not hold back the CI status of a PR. A pass or fail still counts. Names must match exactly, including case.")
                    .foregroundStyle(.secondary)
            }

            GitConfigIgnoredChecksSection()
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
