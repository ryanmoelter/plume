import Foundation

/// How one pane's strip groups each tab with the child sessions that follow
/// it. A group is a tab and the unbroken run of its descendants right after
/// it. Moves keep a group whole (`TabStripMove`), but a child can still sit
/// apart from its parent — moved back from another task, say, or saved by an
/// older build — and then it is not grouped. Ancestry counts only within the
/// pane: a child in another pane is not grouped, and neither is anything
/// below it.
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
    /// Each tab's parent, when the parent is in this pane.
    let parentInPane: [UUID: UUID]

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
        self.parentInPane = parentInPane
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

    /// How many shown chips come before pane position `index`.
    func visibleGap(forPaneIndex index: Int) -> Int {
        ids.prefix(max(index, 0)).count { !hidden.contains($0) }
    }

    /// The positions `id` and its group fill, which move as one.
    func block(of id: UUID) -> ClosedRange<Int>? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return group(parentID: id)?.range ?? index...index
    }

    /// The gaps a tab whose parent is `parentID` may land in without leaving
    /// its parent's group or splitting another: between its siblings, or
    /// between top-level groups when its parent is not in this pane.
    func landingGaps(forChildOf parentID: UUID?) -> [Int] {
        let parentIndex = parentID.flatMap { ids.firstIndex(of: $0) }
        let span: ClosedRange<Int>
        var enclosing: Set<UUID> = []
        if let parentID, let parentIndex {
            span = (parentIndex + 1)...((group(parentID: parentID)?.range.upperBound ?? parentIndex) + 1)
            var current: UUID? = parentID
            while let next = current, enclosing.insert(next).inserted { current = parentInPane[next] }
        } else {
            span = 0...ids.count
        }
        return span.filter { gap in
            groups.allSatisfy { group in
                !(group.range.lowerBound < gap && gap <= group.range.upperBound) || enclosing.contains(group.parentID)
            }
        }
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

/// A tab moving within its strip or into another pane's, carrying its group.
/// A child stays among its siblings, a drop that would leave them clamps to
/// the nearest gap among them, and a group never lands inside another.
nonisolated struct TabStripMove: Equatable {
    /// The moved tab and its descendants, in strip order.
    let ids: [UUID]
    /// The gap they land in, counted in the destination strip without them.
    let gap: Int

    /// Moves `id` toward `requested`, a gap counted with `id` still in place,
    /// or to the end of its siblings when nil.
    static func reorder(_ id: UUID, in pane: [TabStripGrouping.Entry], toward requested: Int?) -> TabStripMove? {
        let grouping = TabStripGrouping(pane)
        guard let block = grouping.block(of: id) else { return nil }
        let rest = Array(pane[..<block.lowerBound] + pane[(block.upperBound + 1)...])
        let target = requested.map { gap in
            if gap <= block.lowerBound { return gap }
            if gap > block.upperBound { return gap - block.count }
            return block.lowerBound
        }
        return landing(grouping.ids[block], parentID: pane[block.lowerBound].parentID, in: rest, near: target)
    }

    /// Moves `id` from `source` into `destination`, toward gap `requested`
    /// there, or to the end when nil. Nil for a child whose parent shares
    /// its pane: it moves only with its parent.
    static func transfer(
        _ id: UUID,
        from source: [TabStripGrouping.Entry],
        to destination: [TabStripGrouping.Entry],
        toward requested: Int?
    ) -> TabStripMove? {
        let grouping = TabStripGrouping(source)
        guard grouping.parentInPane[id] == nil, let block = grouping.block(of: id) else { return nil }
        return landing(grouping.ids[block], parentID: source[block.lowerBound].parentID, in: destination, near: requested)
    }

    private static func landing(
        _ ids: ArraySlice<UUID>,
        parentID: UUID?,
        in rest: [TabStripGrouping.Entry],
        near requested: Int?
    ) -> TabStripMove? {
        let gaps = TabStripGrouping(rest).landingGaps(forChildOf: parentID)
        let target = requested ?? rest.count
        guard let gap = gaps.min(by: { (abs($0 - target), $0) < (abs($1 - target), $1) }) else { return nil }
        return TabStripMove(ids: Array(ids), gap: gap)
    }
}
