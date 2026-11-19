import CoreGraphics
import Foundation

/// Which indirect rows are slid out toward a prompt bar's end, and how far
/// each is headed: 1 out, 0 home.
///
/// Two slots, so that when the hover passes from one indirect row to another
/// the first slides home while the second slides out. A row that is hovered
/// again keeps its slot and turns around from wherever it is.
struct MinimapIndirectSlide: Equatable {
    var rowIDs: [String?] = [nil, nil]
    var targets: [CGFloat] = [0, 0]
    private var lastSlot = 1

    /// Slides `id` out and every other row home. Nil sends them all home.
    mutating func select(_ id: String?) {
        if let id, let slot = rowIDs.firstIndex(of: id) {
            targets = targets.indices.map { $0 == slot ? 1 : 0 }
            lastSlot = slot
            return
        }
        targets = [0, 0]
        guard let id else { return }
        let slot = 1 - lastSlot
        rowIDs[slot] = id
        targets[slot] = 1
        lastSlot = slot
    }

    /// Where an indirect mark's leading edge sits, from the rail's edge: at
    /// rest against it, and slid all the way out so its far end meets the
    /// end of the bar a typed prompt would draw on its row.
    static func offset(progress: CGFloat, promptLength: CGFloat, markLength: CGFloat) -> CGFloat {
        min(max(progress, 0), 1) * max(0, promptLength - markLength)
    }
}
