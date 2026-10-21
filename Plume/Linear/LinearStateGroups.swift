import Foundation

/// One workspace's workflow states, deduplicated by name, type and color:
/// a state that several teams define identically shows once.
nonisolated struct LinearStateGroups: Equatable {
    struct Entry: Equatable, Identifiable {
        let state: LinearWorkflowState
        /// Keys of the teams that define this state, sorted.
        let teamKeys: [String]

        var id: String { state.id }
    }

    struct Section: Equatable, Identifiable {
        enum Kind: Equatable {
            /// The workspace's only section, which needs no heading.
            case onlyTeam
            case sharedByTeams
            case team(LinearTeam)
        }

        let kind: Kind
        let entries: [Entry]

        var id: String {
            switch kind {
            case .onlyTeam: "only"
            case .sharedByTeams: "shared"
            case .team(let team): team.id
            }
        }
    }

    let sections: [Section]

    init(catalog: LinearCatalog) {
        struct Key: Hashable {
            let name: String
            let type: LinearStateType
            let color: String
        }
        var firstState: [Key: LinearWorkflowState] = [:]
        var teamKeys: [Key: Set<String>] = [:]
        for team in catalog.teams {
            for state in team.states {
                let key = Key(name: state.name, type: state.type, color: state.color.lowercased())
                firstState[key] = firstState[key] ?? state
                teamKeys[key, default: []].insert(team.key)
            }
        }
        let entries = firstState.map { key, state in Entry(state: state, teamKeys: teamKeys[key, default: []].sorted()) }

        let teams = catalog.teams.sorted { $0.key < $1.key }
        if teams.count <= 1 {
            sections = entries.isEmpty ? [] : [Section(kind: .onlyTeam, entries: Self.ordered(entries))]
            return
        }
        var sections: [Section] = []
        let shared = entries.filter { $0.teamKeys.count > 1 }
        if !shared.isEmpty { sections.append(Section(kind: .sharedByTeams, entries: Self.ordered(shared))) }
        for team in teams {
            let own = entries.filter { $0.teamKeys == [team.key] }
            if !own.isEmpty { sections.append(Section(kind: .team(team), entries: Self.ordered(own))) }
        }
        if sections.count == 1 {
            sections = [Section(kind: .onlyTeam, entries: sections[0].entries)]
        }
        self.sections = sections
    }

    /// By workflow category, then by name.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        let rank: [LinearStateType] = [.triage, .backlog, .unstarted, .started, .completed, .canceled, .duplicate]
        func position(_ entry: Entry) -> Int { rank.firstIndex(of: entry.state.type) ?? rank.count }
        return entries.sorted {
            let (a, b) = (position($0), position($1))
            return a == b ? $0.state.name < $1.state.name : a < b
        }
    }
}
