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
}
