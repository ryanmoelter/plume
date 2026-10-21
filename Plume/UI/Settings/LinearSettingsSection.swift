import SwiftUI

struct LinearSettingsSection: View {
    @State private var settings = AppSettings.shared
    @State private var store = LinearStore.shared
    @State private var apiKey = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var accountPendingRemoval: LinearAccount?
    @State private var accountShowingInfo: LinearAccount?
    @State private var showsStateColorPreview = false
    @State private var showsAddForm = false

    var body: some View {
        Section {
            Toggle("Show Linear issues", isOn: $settings.showsLinearIssues)
                .plumeID(AccessibilityID.linearShowIssuesToggle, value: settings.showsLinearIssues ? "on" : "off")

            VStack(alignment: .leading, spacing: 10) {
                Text("Workspaces")
                ForEach(store.accounts.accounts) { account in
                    accountRow(account)
                }
                if showsAddForm || store.accounts.accounts.isEmpty {
                    addForm
                } else {
                    showAddFormButton
                }
            }

            Picker(selection: $settings.linearStateColors) {
                ForEach(LinearStateColorStrategy.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                HStack(spacing: 4) {
                    Text("Issue state color mapping")
                    Button {
                        showsStateColorPreview = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Self.accent)
                    }
                    .buttonStyle(.borderless)
                    .help("Preview every workflow state's color")
                    .plumeID(AccessibilityID.linearStateColorsPreviewButton, invoke: { showsStateColorPreview = true })
                    .popover(isPresented: $showsStateColorPreview, arrowEdge: .trailing) {
                        LinearStateColorPreview()
                    }
                }
            }
            .plumeID(AccessibilityID.linearStateColorsPicker, value: settings.linearStateColors.rawValue)

        } header: {
            Text("Linear")
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

    /// Marks what is clickable; resolves per appearance and honors the
    /// accent chosen in settings.
    static var accent: Color { Color(nsColor: ThemeChrome.accentNSColor()) }

    static let createKeyURL = URL(string: "https://linear.app/settings/account/security")!

    private func accountRow(_ account: LinearAccount) -> some View {
        let status = Self.statusLine(for: store.accountStatus(orgID: account.orgID))
        return HStack(spacing: 8) {
            Button {
                accountPendingRemoval = account
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
                    .frame(width: Self.leadingIconWidth)
            }
            .buttonStyle(.borderless)
            .help("Remove this workspace")
            .plumeID(AccessibilityID.linearRemoveAccountButton, label: account.orgName, invoke: {
                accountPendingRemoval = account
            })
            VStack(alignment: .leading, spacing: 2) {
                Text(account.orgName)
                LinearViewerName(name: account.viewerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            Button {
                accountShowingInfo = account
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Self.accent)
            }
            .buttonStyle(.borderless)
            .help("What Plume knows about this workspace")
            .plumeID(AccessibilityID.linearAccountInfoButton, label: account.orgName, invoke: {
                accountShowingInfo = account
            })
            .popover(
                isPresented: Binding(
                    get: { accountShowingInfo == account },
                    set: { if !$0 { accountShowingInfo = nil } }
                ),
                arrowEdge: .trailing
            ) {
                LinearAccountInfo(account: account)
            }
            Spacer(minLength: 0)
        }
        .plumeID(AccessibilityID.linearAccountRow, label: account.orgName)
    }

    private var canAdd: Bool {
        !isAdding && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Personal API key", text: $apiKey, prompt: Text("Personal API key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(add)
                    .plumeID(AccessibilityID.linearAPIKeyField, setValue: { apiKey = $0 })
                Button("Cancel", action: cancelAdding)
                    .plumeID(AccessibilityID.linearCancelAddButton, invoke: cancelAdding)
                Button("Add", action: add)
                    .plumeID(AccessibilityID.linearAddAccountButton, invoke: add)
                    .disabled(!canAdd)
                if isAdding {
                    ProgressView().controlSize(.small)
                }
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 4) {
                Image(systemName: "lock").imageScale(.small)
                Text("Securely stored in your Keychain")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Link(destination: Self.createKeyURL) {
                HStack(spacing: 2) {
                    Text("Create a new API key")
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .font(.caption)
            .foregroundStyle(Self.accent)
            .plumeID(AccessibilityID.linearCreateKeyLink)
        }
    }

    private var showAddFormButton: some View {
        Button {
            showsAddForm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").frame(width: Self.leadingIconWidth)
                Text("Add")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Self.accent)
        .plumeID(AccessibilityID.linearShowAddFormButton, invoke: { showsAddForm = true })
    }

    /// Keeps the workspace names and the "Add" text in one column.
    private static let leadingIconWidth: CGFloat = 18

    private func cancelAdding() {
        apiKey = ""
        addError = nil
        showsAddForm = false
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
                showsAddForm = false
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
            StatusLine(text: "API key rejected — add a new key for this workspace", isError: true)
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

/// The connected user, marked with a person icon instead of a label.
struct LinearViewerName: View {
    let name: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "person")
            Text(name)
        }
    }
}
