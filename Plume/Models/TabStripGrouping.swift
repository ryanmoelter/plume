import Foundation

/// How one pane's strip groups each tab with the child sessions attached to
/// it. Attachment is positional, never stored: a tab's run is the tab and the
/// unbroken sequence right after it of tabs whose own parent is already in
/// the run. A child anywhere else — after an unrelated tab, in another pane
/// or another task — is detached, and so is everything below it.
nonisolated struct TabStripGrouping: Equatable {
    struct Entry: Equatable {
        let id: UUID
        let parentID: UUID?
        var childrenCollapsed = false
    }

    struct Group: Equatable {
        let parentID: UUID
        /// Indices into the pane's tabs: the parent, then its attached descendants.
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
        var ranges: [(parentID: UUID, range: ClosedRange<Int>, isCollapsed: Bool)] = []
        for (index, entry) in entries.enumerated() {
            var run: Set<UUID> = [entry.id]
            var end = index
            while end + 1 < entries.count, let parent = entries[end + 1].parentID, run.contains(parent),
                  run.insert(entries[end + 1].id).inserted {
                end += 1
            }
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

    /// How many shown chips come before pane position `index`.
    func visibleGap(forPaneIndex index: Int) -> Int {
        ids.prefix(max(index, 0)).count { !hidden.contains($0) }
    }

    /// The positions `id` and its group fill, which move as one.
    func block(of id: UUID) -> ClosedRange<Int>? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return group(parentID: id)?.range ?? index...index
    }

    /// Whether `id` sits in the run of its parent `parentID`.
    func isAttached(_ id: UUID, to parentID: UUID) -> Bool {
        guard let index = ids.firstIndex(of: id), let range = group(parentID: parentID)?.range else { return false }
        return range.lowerBound < index && range.contains(index)
    }

    /// The gap just past `parentID`'s run, where a newly attached child goes.
    func endOfRun(of parentID: UUID) -> Int? {
        guard let index = ids.firstIndex(of: parentID) else { return nil }
        return (group(parentID: parentID)?.range.upperBound ?? index) + 1
    }

    /// The gap nearest `requested` where a tab whose parent is `parentID`
    /// lands without splitting a run: inside a run it joins, it stays; inside
    /// one it would break, it goes to just past that run.
    func landingGap(forChildOf parentID: UUID?, near requested: Int) -> Int {
        let gap = min(max(requested, 0), ids.count)
        let refusing = groups.filter { group in
            group.range.lowerBound < gap && gap <= group.range.upperBound
                && !(parentID.map { ids[group.range.lowerBound..<gap].contains($0) } ?? false)
        }
        guard let outermost = refusing.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { return gap }
        return outermost.range.upperBound + 1
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

/// A tab moving within its strip or into another pane's, carrying the
/// children attached to it. It lands where it is dropped, except that it
/// never splits a run it would not join (`TabStripGrouping.landingGap`).
nonisolated struct TabStripMove: Equatable {
    /// The moved tab and its attached descendants, in strip order.
    let ids: [UUID]
    /// The gap they land in, counted in the destination strip without them.
    let gap: Int

    /// Moves `id` toward `requested`, a gap counted with `id` still in place,
    /// or to the strip's end when nil.
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
    /// there, or to the end when nil.
    static func transfer(
        _ id: UUID,
        from source: [TabStripGrouping.Entry],
        to destination: [TabStripGrouping.Entry],
        toward requested: Int?
    ) -> TabStripMove? {
        let grouping = TabStripGrouping(source)
        guard let block = grouping.block(of: id) else { return nil }
        return landing(grouping.ids[block], parentID: source[block.lowerBound].parentID, in: destination, near: requested)
    }

    private static func landing(
        _ ids: ArraySlice<UUID>,
        parentID: UUID?,
        in rest: [TabStripGrouping.Entry],
        near requested: Int?
    ) -> TabStripMove {
        let gap = TabStripGrouping(rest).landingGap(forChildOf: parentID, near: requested ?? rest.count)
        return TabStripMove(ids: Array(ids), gap: gap)
    }
}
