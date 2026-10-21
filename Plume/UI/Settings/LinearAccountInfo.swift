import SwiftUI

/// Everything Plume has fetched for one workspace: its teams, their workflow
/// states as Plume draws them, and the key's request budget.
struct LinearAccountInfo: View {
    let account: LinearAccount

    @State private var store = LinearStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                Divider()
                if let catalog = store.catalog(orgID: account.orgID) {
                    ForEach(catalog.teams.sorted { $0.key < $1.key }, id: \.id) { team in
                        TeamStates(team: team)
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
            HStack {
                Text(account.orgName).font(.headline)
                Spacer()
                Button("Refresh") { store.refreshCatalog(orgID: account.orgID) }
                    .controlSize(.small)
                    .plumeID(AccessibilityID.linearAccountRefreshButton, label: account.orgName, invoke: {
                        store.refreshCatalog(orgID: account.orgID)
                    })
            }
            Group {
                fact("Workspace", "linear.app/\(account.urlKey)")
                fact("Connected as", account.viewerName)
                fact("Status", Self.statusWord(store.accountStatus(orgID: account.orgID)))
                fact("Team keys", catalog.map { $0.teams.map(\.key).sorted().joined(separator: ", ") } ?? "—")
                fact("Teams fetched", catalog.map { $0.fetchedAt.formatted(.relative(presentation: .named)) } ?? "never")
                fact("Requests left", Self.budget(store.rateLimit(orgID: account.orgID)))
                fact("Organization ID", account.orgID)
            }
            .font(.caption)
        }
        .textSelection(.enabled)
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

private struct TeamStates: View {
    let team: LinearTeam

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(team.key).fontWeight(.semibold)
                Text(team.name).foregroundStyle(.secondary)
            }
            ForEach(Self.ordered(team.states), id: \.id) { state in
                HStack(spacing: 6) {
                    LinearIssueGlyph(stateType: state.type, colorHex: state.color)
                        .frame(width: 16)
                    Text(state.name)
                    Spacer(minLength: 8)
                    Text(state.type.rawValue).foregroundStyle(.secondary)
                    Circle()
                        .fill(Color(hex: state.color) ?? .clear)
                        .frame(width: 8, height: 8)
                        .help("Linear's color")
                    Text(state.color.uppercased())
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    /// By workflow category, then by name.
    static func ordered(_ states: [LinearWorkflowState]) -> [LinearWorkflowState] {
        let rank: [String] = ["triage", "backlog", "unstarted", "started", "completed", "canceled"]
        return states.sorted {
            let (a, b) = (rank.firstIndex(of: $0.type.rawValue) ?? rank.count, rank.firstIndex(of: $1.type.rawValue) ?? rank.count)
            return a == b ? $0.name < $1.name : a < b
        }
    }
}
