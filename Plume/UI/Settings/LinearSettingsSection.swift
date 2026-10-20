import SwiftUI

struct LinearSettingsSection: View {
    @State private var settings = AppSettings.shared
    @State private var store = LinearStore.shared
    @State private var apiKey = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var accountPendingRemoval: LinearAccount?

    var body: some View {
        Section {
            Toggle("Show Linear issues", isOn: $settings.showsLinearIssues)
                .plumeID(AccessibilityID.linearShowIssuesToggle, value: settings.showsLinearIssues ? "on" : "off")

            ForEach(store.accounts.accounts) { account in
                accountRow(account)
            }

            addRow

            Link(destination: Self.createKeyURL) {
                HStack(spacing: 4) {
                    Text("Create a personal API key")
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .plumeID(AccessibilityID.linearCreateKeyLink)
        } header: {
            Text("Linear")
        } footer: {
            Text("Keys are stored in your Keychain. Add one per workspace; issues route by team key.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Remove \(accountPendingRemoval?.orgName ?? "workspace")?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove", role: .destructive) {
                store.accounts.remove(orgID: account.orgID)
            }
        } message: { _ in
            Text("Plume deletes its stored API key for this workspace.")
        }
    }

    static let createKeyURL = URL(string: "https://linear.app/settings/account/security")!

    private func accountRow(_ account: LinearAccount) -> some View {
        let status = Self.statusLine(for: store.accountStatus(orgID: account.orgID))
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.orgName)
                Text("Connected as \(account.viewerName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            Spacer()
            Button("Remove", role: .destructive) {
                accountPendingRemoval = account
            }
            .plumeID(AccessibilityID.linearRemoveAccountButton, label: account.orgName, invoke: {
                accountPendingRemoval = account
            })
        }
        .plumeID(AccessibilityID.linearAccountRow, label: account.orgName)
    }

    private var canAdd: Bool {
        !isAdding && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("Personal API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .plumeID(AccessibilityID.linearAPIKeyField, setValue: { apiKey = $0 })
                if isAdding {
                    ProgressView().controlSize(.small)
                }
                Button("Add", action: add)
                    .plumeID(AccessibilityID.linearAddAccountButton, invoke: add)
                    .disabled(!canAdd)
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func add() {
        guard canAdd else { return }
        let key = apiKey
        isAdding = true
        addError = nil
        Task {
            do {
                try await store.accounts.add(apiKey: key)
                apiKey = ""
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }

    struct StatusLine: Equatable {
        let text: String
        let isError: Bool
    }

    static func statusLine(for status: LinearAccountStatus, now: Date = .now) -> StatusLine? {
        switch status {
        case .unknown, .connected:
            nil
        case .unauthorized:
            StatusLine(text: "API key rejected — remove and add a new one", isError: true)
        case .rateLimited(let until):
            StatusLine(
                text: "Rate limited until \(until.formatted(date: .omitted, time: .shortened))",
                isError: false
            )
        case .failed(let message):
            StatusLine(text: message, isError: true)
        }
    }
}
