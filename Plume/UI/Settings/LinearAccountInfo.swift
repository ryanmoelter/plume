import SwiftUI

/// What Plume has fetched for one workspace: its teams and the key's request
/// budget. `LinearStateColorPreview` shows the workflow states.
struct LinearAccountInfo: View {
    let account: LinearAccount

    @State private var store = LinearStore.shared
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                Divider()
                if let catalog = store.catalog(orgID: account.orgID) {
                    ForEach(catalog.teams.sorted { $0.key < $1.key }, id: \.id) { team in
                        TeamRow(team: team)
                    }
                } else {
                    Text("No teams fetched yet").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .plumeTheme(bodySize: NSFont.systemFontSize, setsAmbientFont: false)
    }

    private var summary: some View {
        let catalog = store.catalog(orgID: account.orgID)
        return VStack(alignment: .leading, spacing: 4) {
            Text(account.orgName).font(.headline)
            Group {
                Text("linear.app/\(account.urlKey)").foregroundStyle(.secondary)
                LinearViewerName(name: account.viewerName)
                HStack(spacing: 4) {
                    Text(Self.statusLine(store.accountStatus(orgID: account.orgID), fetchedAt: catalog?.fetchedAt))
                    Button {
                        store.refreshCatalog(orgID: account.orgID)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LinearSettingsSection.accent)
                    .help("Fetch teams and states again")
                    .plumeID(AccessibilityID.linearAccountRefreshButton, label: account.orgName, invoke: {
                        store.refreshCatalog(orgID: account.orgID)
                    })
                }
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Details")
                        DisclosureChevron(isExpanded: showsDetails)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .plumeID(AccessibilityID.linearAccountDetailsToggle, label: account.orgName, value: showsDetails ? "expanded" : "collapsed", invoke: {
                    showsDetails.toggle()
                })
                if showsDetails {
                    fact("Requests left", Self.budget(store.rateLimit(orgID: account.orgID)))
                    fact("Organization ID", account.orgID)
                }
            }
            .font(.caption)
        }
        .textSelection(.enabled)
    }

    /// "Connected, 39 minutes ago": the status, and when the teams last
    /// arrived.
    static func statusLine(_ status: LinearAccountStatus, fetchedAt: Date?) -> String {
        let word = statusWord(status)
        guard let fetchedAt else { return word }
        return "\(word), \(fetchedAt.formatted(.relative(presentation: .named)))"
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
    }

    static func statusWord(_ status: LinearAccountStatus) -> String {
        switch status {
        case .unknown: "Checking"
        case .connected: "Connected"
        case .unauthorized: "Key rejected"
        case .rateLimited(let until): "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): message
        }
    }

    static func budget(_ limit: LinearRateLimit?) -> String {
        guard let limit else { return "no request yet" }
        return "\(limit.remaining) of \(limit.limit), resets \(limit.resetAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct TeamRow: View {
    let team: LinearTeam

    var body: some View {
        HStack(spacing: 6) {
            Text(team.key).fontWeight(.semibold)
            Text(team.name).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(team.states.count) states").foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
