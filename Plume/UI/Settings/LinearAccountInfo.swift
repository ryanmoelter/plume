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
                    TeamTable(teams: catalog.teams.sorted { $0.key < $1.key })
                } else {
                    Text("No teams fetched yet").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 280)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .plumeTheme(bodySize: NSFont.systemFontSize, setsAmbientFont: false)
    }

    private var summary: some View {
        let catalog = store.catalog(orgID: account.orgID)
        return VStack(alignment: .leading, spacing: 4) {
            Text(account.orgName).font(.title3.weight(.semibold))
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
            .font(.callout)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
        .padding(.top, 2)
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

private struct TeamTable: View {
    let teams: [LinearTeam]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Text("Teams").gridCellColumns(2)
                Text("Issue states").gridColumnAlignment(.trailing)
            }
            .foregroundStyle(.secondary)
            ForEach(teams, id: \.id) { team in
                GridRow {
                    Text(team.key).fontWeight(.semibold)
                    Text(team.name)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(team.states.count)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}
