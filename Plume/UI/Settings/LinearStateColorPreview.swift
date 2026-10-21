import SwiftUI

/// Every workflow state of every connected workspace, drawn in Linear's color
/// and then as Plume maps it.
struct LinearStateColorPreview: View {
    @State private var store = LinearStore.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.accounts.accounts.isEmpty {
                    Text("No workspaces connected").foregroundStyle(.secondary)
                }
                ForEach(store.accounts.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.orgName).font(.headline)
                        if let catalog = store.catalog(orgID: account.orgID) {
                            ForEach(LinearStateGroups(catalog: catalog).sections) { section in
                                SectionView(section: section, strategy: settings.linearStateColors)
                            }
                        } else {
                            Text("No teams fetched yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 320)
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
        .plumeTheme(bodySize: NSFont.systemFontSize, setsAmbientFont: false)
    }
}

private struct SectionView: View {
    let section: LinearStateGroups.Section
    let strategy: LinearStateColorStrategy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch section.kind {
            case .onlyTeam: EmptyView()
            case .sharedByTeams: heading("Multiple teams", nil)
            case .team(let team): heading(team.name, team.key)
            }
            ForEach(section.entries) { entry in
                HStack(spacing: 6) {
                    LinearIssueGlyph(stateType: entry.state.type, colorHex: entry.state.color, strategy: nil)
                        .frame(width: 16)
                        .help("Linear's color")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    LinearIssueGlyph(stateType: entry.state.type, colorHex: entry.state.color, strategy: strategy)
                        .frame(width: 16)
                    Text(entry.state.name)
                    Spacer(minLength: 8)
                    if section.kind == .sharedByTeams {
                        Text(entry.teamKeys.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.leading, section.kind == .onlyTeam ? 0 : 8)
    }

    private func heading(_ title: String, _ key: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.semibold)
            if let key { Text(key).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.leading, -8)
    }
}
