import Foundation

/// How many agent header lines a task's sidebar row shows before folding the
/// rest behind a toggle.
enum AgentRowCap {
    static let limit = 4

    struct Layout: Equatable {
        let visibleCount: Int
        /// Nil when everything fits, so no toggle shows.
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

    /// `lines` folded past the limit. Folding never hides the focused
    /// agent's header, and the toggle counts only what it does hide.
    static func fold(
        _ lines: [TaskRowDetails.Line],
        isExpanded: Bool,
        focusedTabID: UUID?
    ) -> (lines: [TaskRowDetails.Line], layout: Layout) {
        let total = TaskRowDetails.headerCount(lines)
        let unfolded = layout(total: total, isExpanded: isExpanded)
        guard total > limit, !isExpanded else { return (lines, unfolded) }
        let folded = TaskRowDetails.lines(lines, keepingHeaders: limit, alsoKeeping: focusedTabID)
        let visible = total - folded.hiddenHeaders
        guard folded.hiddenHeaders > 0 else {
            return (folded.lines, Layout(visibleCount: visible, toggleTitle: nil, toggleSymbol: nil))
        }
        return (folded.lines, Layout(
            visibleCount: visible,
            toggleTitle: "Show \(folded.hiddenHeaders) more",
            toggleSymbol: "chevron.down"
        ))
    }
}
