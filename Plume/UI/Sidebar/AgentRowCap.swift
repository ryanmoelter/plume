import Foundation

/// How many agent header lines a task's sidebar row shows before folding the
/// rest behind a toggle.
enum AgentRowCap {
    static let limit = 4

    struct Layout: Equatable {
        let visibleCount: Int
        /// Nil when folding would hide nothing, so no toggle shows.
        let toggleTitle: String?
        let toggleSymbol: String?
    }

    static func layout(total: Int, isExpanded: Bool) -> Layout {
        guard total > limit else { return Layout(visibleCount: total, toggleTitle: nil, toggleSymbol: nil) }
        if isExpanded {
            return Layout(visibleCount: total, toggleTitle: "Show fewer", toggleSymbol: "chevron.up")
        }
        return Layout(visibleCount: limit, toggleTitle: "Show \(total - limit) more", toggleSymbol: "chevron.down")
    }

    struct Folded {
        let lines: [TaskRowDetails.Line]
        let layout: Layout
        /// The tabs whose headers the fold hides, in row order.
        let hiddenTabIDs: [UUID]
    }

    /// `lines` folded past the limit. Folding never hides the focused
    /// agent's header, and the toggle counts only what it does hide.
    static func fold(_ lines: [TaskRowDetails.Line], isExpanded: Bool, focusedTabID: UUID?) -> Folded {
        let total = TaskRowDetails.headerCount(lines)
        guard total > limit else {
            return Folded(lines: lines, layout: layout(total: total, isExpanded: isExpanded), hiddenTabIDs: [])
        }
        let folded = TaskRowDetails.lines(lines, keepingHeaders: limit, alsoKeeping: focusedTabID)
        let hidden = folded.hiddenTabIDs.count
        if isExpanded {
            let toggles = hidden > 0
            let layout = Layout(
                visibleCount: total,
                toggleTitle: toggles ? "Show fewer" : nil,
                toggleSymbol: toggles ? "chevron.up" : nil
            )
            return Folded(lines: lines, layout: layout, hiddenTabIDs: [])
        }
        let layout = Layout(
            visibleCount: total - hidden,
            toggleTitle: hidden > 0 ? "Show \(hidden) more" : nil,
            toggleSymbol: hidden > 0 ? "chevron.down" : nil
        )
        return Folded(lines: folded.lines, layout: layout, hiddenTabIDs: folded.hiddenTabIDs)
    }
}
