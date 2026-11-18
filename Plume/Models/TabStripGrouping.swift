import Foundation

/// How one pane's strip groups each tab with the child sessions that follow
/// it. A group is a tab and the unbroken run of its descendants right after
/// it, so a child dragged away from its parent leaves the group. Ancestry
/// counts only within the pane: a child in another pane is not grouped, and
/// neither is anything below it.
nonisolated struct TabStripGrouping: Equatable {
    struct Entry: Equatable {
        let id: UUID
        let parentID: UUID?
        var childrenCollapsed = false
    }

    struct Group: Equatable {
        let parentID: UUID
        /// Indices into the pane's tabs: the parent, then its descendants.
        let range: ClosedRange<Int>
        /// How many groups enclose this one.
        let depth: Int
        let isCollapsed: Bool

        var descendantCount: Int { range.count - 1 }
    }

    /// The pane's tabs, in strip order.
    let ids: [UUID]
    /// In order of their parents' positions. Ranges nest or are disjoint.
    let groups: [Group]
    /// Tabs whose chips a collapsed group hides.
    let hidden: Set<UUID>

    init(_ entries: [Entry]) {
        ids = entries.map(\.id)
        let indexByID = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let parentInPane: [UUID: UUID] = entries.reduce(into: [:]) { result, entry in
            if let parent = entry.parentID, parent != entry.id, indexByID[parent] != nil {
                result[entry.id] = parent
            }
        }
        func descends(_ id: UUID, from ancestor: UUID) -> Bool {
            var visited: Set<UUID> = [id]
            var current = parentInPane[id]
            while let next = current {
                if next == ancestor { return true }
                guard visited.insert(next).inserted else { return false }
                current = parentInPane[next]
            }
            return false
        }

        var ranges: [(parentID: UUID, range: ClosedRange<Int>, isCollapsed: Bool)] = []
        for (index, entry) in entries.enumerated() {
            var end = index
            while end + 1 < entries.count, descends(entries[end + 1].id, from: entry.id) { end += 1 }
            if end > index { ranges.append((entry.id, index...end, entry.childrenCollapsed)) }
        }
        groups = ranges.map { group in
            let depth = ranges.count { $0.range.lowerBound < group.range.lowerBound && $0.range.contains(group.range.lowerBound) }
            return Group(parentID: group.parentID, range: group.range, depth: depth, isCollapsed: group.isCollapsed)
        }
        var hidden: Set<UUID> = []
        for group in groups where group.isCollapsed {
            hidden.formUnion(ids[group.range].dropFirst())
        }
        self.hidden = hidden
    }

    var visibleIDs: [UUID] { ids.filter { !hidden.contains($0) } }

    func group(parentID: UUID) -> Group? {
        groups.first { $0.parentID == parentID }
    }

    /// Groups whose parent's chip shows, the ones the strip draws.
    var visibleGroups: [Group] {
        groups.filter { !hidden.contains($0.parentID) }
    }

    /// The last tab of `group` whose chip shows, where its bar ends.
    func lastVisibleID(in group: Group) -> UUID {
        ids[group.range].last { !hidden.contains($0) } ?? group.parentID
    }

    /// The parents of the collapsed groups that hide `id`, which must expand
    /// for its chip to show.
    func collapsedParentsHiding(_ id: UUID) -> [UUID] {
        guard hidden.contains(id), let index = ids.firstIndex(of: id) else { return [] }
        return groups
            .filter { $0.isCollapsed && $0.range.lowerBound < index && $0.range.contains(index) }
            .map(\.parentID)
    }

    /// The position in the whole pane of the gap before visible chip `gap`,
    /// or the pane's end past the last chip. A drop never lands among a
    /// collapsed group's hidden chips.
    func paneIndex(forVisibleGap gap: Int) -> Int {
        let visible = visibleIDs
        guard visible.indices.contains(gap) else { return ids.count }
        return ids.firstIndex(of: visible[gap]) ?? ids.count
    }

    /// What a pane showing `shown` should show once `parentID` collapses:
    /// the parent, when the collapse hides the shown tab, and nil otherwise.
    func shownAfterCollapsing(_ parentID: UUID, shown: UUID?) -> UUID? {
        guard let shown, let group = group(parentID: parentID),
              let index = ids.firstIndex(of: shown),
              group.range.lowerBound < index, group.range.contains(index)
        else { return nil }
        return parentID
    }
}
