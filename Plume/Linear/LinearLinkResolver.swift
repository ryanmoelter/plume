import Foundation

/// Folds every source of a task's Linear links into one classified list.
nonisolated enum LinearLinkResolver {
    static func resolve(
        evidence: [LinearEvidence],
        branchIdentifiers: [String],
        links: LinearTaskLinks,
        catalogs: [LinearCatalog]
    ) -> [LinkedLinearIssue] {
        struct Entry {
            var sources: Set<LinearLinkSource> = []
            var subagents: [LinearSubagentRef] = []
            var touchedByMainAgent = false
            var started = false
            var order = 0
        }
        var entries: [String: Entry] = [:]
        var nextOrder = 0

        func update(_ identifier: String, _ change: (inout Entry) -> Void) {
            var entry = entries[identifier] ?? Entry(order: nextOrder)
            if entries[identifier] == nil { nextOrder += 1 }
            change(&entry)
            entries[identifier] = entry
        }

        let teamKeys = catalogs.reduce(into: Set<String>()) { $0.formUnion($1.teamKeys) }
        let dismissed = Set(links.dismissed.map { $0.uppercased() })
        let manualIDs = Set(links.manual.map(\.identifier))

        for ref in links.manual { update(ref.identifier) { $0.sources.insert(.manual) } }
        for identifier in LinearIdentifier.filter(branchIdentifiers.map { $0.uppercased() }, teamKeys: teamKeys) {
            update(identifier) { $0.sources.insert(.branch) }
        }
        for ref in links.promoted { update(ref.identifier) { $0.sources.insert(.promoted) } }
        for ref in links.agentStarted { update(ref.identifier) { $0.sources.insert(.agentStarted) } }

        for item in evidence {
            let identifier = item.identifier.uppercased()
            guard teamKeys.contains(LinearIdentifier.teamKey(of: identifier)) else { continue }
            let started = item.outcome != .failed && isStartRequest(item, catalogs: catalogs)
            update(identifier) { entry in
                entry.sources.insert(.agent)
                entry.started = entry.started || started
                if let subagent = item.subagent {
                    if !entry.subagents.contains(subagent) { entry.subagents.append(subagent) }
                } else {
                    entry.touchedByMainAgent = true
                }
            }
        }

        let linked: [LinkedLinearIssue] = entries.compactMap { identifier, entry in
            guard !dismissed.contains(identifier) || manualIDs.contains(identifier) else { return nil }
            let working = entry.started || !entry.sources.isDisjoint(with: [.manual, .promoted, .branch, .agentStarted])
            return LinkedLinearIssue(
                identifier: identifier,
                role: working ? .working : .mentioned,
                sources: entry.sources,
                subagents: entry.subagents,
                touchedByMainAgent: entry.touchedByMainAgent
            )
        }

        func rank(_ issue: LinkedLinearIssue) -> (LinearLinkRole, LinearLinkSource, Int) {
            (issue.role, issue.sources.min() ?? .agent, entries[issue.identifier]?.order ?? 0)
        }
        return linked.sorted { rank($0) < rank($1) }
    }

    /// Only calls that succeeded, since these are persisted on the task.
    static func startedIdentifiers(evidence: [LinearEvidence], catalogs: [LinearCatalog]) -> Set<String> {
        Set(evidence
            .filter { $0.outcome == .succeeded && isStartRequest($0, catalogs: catalogs) }
            .map { $0.identifier.uppercased() })
    }

    private static func isStartRequest(_ item: LinearEvidence, catalogs: [LinearCatalog]) -> Bool {
        guard let requested = item.requestedState, !requested.isEmpty,
              item.isWrite
        else { return false }
        let key = LinearIdentifier.teamKey(of: item.identifier)
        guard let team = catalogs.lazy.compactMap({ $0.team(key: key) }).first else { return false }
        let state = team.states.first { $0.id == requested }
            ?? team.states.first { $0.name.caseInsensitiveCompare(requested) == .orderedSame }
        if let state { return state.type == .started }
        return LinearStateType(rawValue: requested) == .started
    }
}
