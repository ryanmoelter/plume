import CoreGraphics
import Foundation

/// One lazy item's slot in a `ChatLayoutModel`.
struct ChatLayoutItem: Equatable {
    var id: String
    /// Gap paid above the item, outside its content.
    var topInset: CGFloat = 0
    /// Gap paid below the item, outside its content.
    var bottomInset: CGFloat = 0
    /// Starting height until the first measurement replaces it.
    var estimatedHeight: CGFloat
}

/// The pure layout brain of the custom chat list.
///
/// Owns item order, per-item heights, prefix-sum offsets, which items are
/// realized, the slack that pins a sent prompt to the top of the viewport,
/// and the arithmetic for preserving where the reader was looking when
/// heights above them change. No AppKit, no SwiftUI, no knowledge of
/// `ChatPiece` — a measured height stops here and never flows back into
/// `ChatPieceSplitter`.
struct ChatLayoutModel {
    private struct Entry {
        var item: ChatLayoutItem
        var targetHeight: CGFloat
        var displayHeight: CGFloat
        var generation: Int = 0
        var hasMeasurement: Bool = false
    }

    let overscan: CGFloat
    let maxRealized: Int

    private var entries: [Entry] = []
    private var indexByID: [String: Int] = [:]
    /// `prefixSums[i]` is the y where slot `i` starts; `prefixSums[count]` is
    /// `contentHeight`. Rebuilt eagerly on every mutation that can move a
    /// slot boundary, so every geometry query below stays a plain read.
    private var prefixSums: [CGFloat] = [0]

    var measurementWidth: CGFloat = 0

    var viewportHeight: CGFloat = 0 {
        didSet { recomputeSlack() }
    }

    var trailingInset: CGFloat = 0 {
        didSet { recomputeSlack() }
    }

    private(set) var anchorID: String?
    private(set) var slack: CGFloat = 0
    /// Latched once the reply has filled the viewport, until the next
    /// `setAnchor`: from then on content shrinking keeps the reader at the
    /// bottom instead of snapping the prompt back to the top.
    private var slackExhausted = false

    init(overscan: CGFloat = 0.5, maxRealized: Int = 120) {
        self.overscan = overscan
        self.maxRealized = maxRealized
    }

    // MARK: - Items

    mutating func setItems(_ items: [ChatLayoutItem]) {
        var newEntries: [Entry] = []
        newEntries.reserveCapacity(items.count)
        var newIndex: [String: Int] = [:]
        for item in items {
            newIndex[item.id] = newEntries.count
            if let oldIndex = indexByID[item.id] {
                var entry = entries[oldIndex]
                entry.item = item
                newEntries.append(entry)
            } else {
                newEntries.append(Entry(
                    item: item,
                    targetHeight: item.estimatedHeight,
                    displayHeight: item.estimatedHeight
                ))
            }
        }
        entries = newEntries
        indexByID = newIndex
        invalidate()
    }

    /// Replaces the guess for an item that has not measured yet. A measured
    /// item keeps its measurement.
    mutating func updateEstimate(_ height: CGFloat, for id: String) {
        updateEstimates([id: height])
    }

    /// One recompute for the whole batch; a width change re-estimates
    /// every unmeasured item at once.
    mutating func updateEstimates(_ heights: [String: CGFloat]) {
        var changed = false
        for (id, height) in heights {
            guard let index = indexByID[id], !entries[index].hasMeasurement else { continue }
            entries[index].item.estimatedHeight = height
            entries[index].targetHeight = height
            entries[index].displayHeight = height
            changed = true
        }
        if changed { invalidate() }
    }

    // MARK: - Heights

    func targetHeight(of id: String) -> CGFloat {
        guard let index = indexByID[id] else { return 0 }
        return entries[index].targetHeight
    }

    func displayHeight(of id: String) -> CGFloat {
        guard let index = indexByID[id] else { return 0 }
        return entries[index].displayHeight
    }

    mutating func setDisplayHeight(_ height: CGFloat, for id: String) {
        guard let index = indexByID[id] else { return }
        entries[index].displayHeight = height
        invalidate()
    }

    mutating func snapDisplayHeights() {
        for index in entries.indices {
            entries[index].displayHeight = entries[index].targetHeight
        }
        invalidate()
    }

    // MARK: - Stamped measurements

    func hasMeasurement(_ id: String) -> Bool {
        guard let index = indexByID[id] else { return false }
        return entries[index].hasMeasurement
    }

    mutating func realize(_ id: String) -> Int {
        guard let index = indexByID[id] else { return 0 }
        entries[index].generation += 1
        return entries[index].generation
    }

    @discardableResult
    mutating func setTargetHeight(
        _ height: CGFloat,
        for id: String,
        width: CGFloat,
        generation: Int
    ) -> Bool {
        guard let index = indexByID[id] else { return false }
        guard width == measurementWidth, generation == entries[index].generation else { return false }
        let firstMeasurement = !entries[index].hasMeasurement
        entries[index].targetHeight = height
        entries[index].hasMeasurement = true
        if firstMeasurement {
            // A freshly realized row must not ease up from its estimate.
            entries[index].displayHeight = height
        }
        invalidate()
        return true
    }

    // MARK: - Geometry

    func slotTop(of id: String) -> CGFloat {
        guard let index = indexByID[id] else { return 0 }
        return prefixSums[index]
    }

    func frame(of id: String) -> CGRect? {
        guard let index = indexByID[id] else { return nil }
        let entry = entries[index]
        let top = prefixSums[index] + entry.item.topInset
        return CGRect(x: 0, y: top, width: measurementWidth, height: entry.displayHeight)
    }

    var contentHeight: CGFloat { prefixSums[entries.count] }

    var totalHeight: CGFloat { contentHeight + slack + trailingInset }

    var maxOffset: CGFloat { max(0, totalHeight - viewportHeight) }

    // MARK: - Slack (send-to-top)

    mutating func setAnchor(_ id: String?) {
        anchorID = id
        slackExhausted = false
        recomputeSlack()
    }

    private mutating func recomputeSlack() {
        // Hidden tab: leave slack and the cap untouched until it shows again.
        guard viewportHeight > 0 else { return }
        guard let anchorID, let index = indexByID[anchorID] else {
            slack = 0
            return
        }
        let anchorTop = prefixSums[index]
        let formula = max(0, viewportHeight - (contentHeight - anchorTop) - trailingInset)
        // Below the fill line the formula rules outright, so a streaming
        // block that re-wraps a line taller for a frame takes nothing away.
        if formula == 0 { slackExhausted = true }
        slack = slackExhausted ? 0 : formula
    }

    // MARK: - Windows

    func realizedRange(offset: CGFloat) -> Range<Int> {
        realizedRange(offset: offset, overscan: overscan)
    }

    /// The same window at another overscan, so a controller can keep hosts
    /// for longer than it takes to realize them.
    func realizedRange(offset: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard viewportHeight > 0, !entries.isEmpty else { return 0..<0 }
        let lower = offset - overscan * viewportHeight
        let upper = offset + viewportHeight + overscan * viewportHeight

        let start = firstIndexWhereSlotEndExceeds(lower)
        let lastInclusive = lastIndexWhereSlotStartIsBelow(upper)
        guard start <= lastInclusive else { return 0..<0 }

        var lo = start
        var hi = lastInclusive + 1
        var dropFront = true
        while hi - lo > maxRealized {
            if dropFront { lo += 1 } else { hi -= 1 }
            dropFront.toggle()
        }
        return lo..<hi
    }

    func visibleIDs(offset: CGFloat) -> [String] {
        guard viewportHeight > 0, !entries.isEmpty else { return [] }
        let windowStart = offset
        let windowEnd = offset + viewportHeight - trailingInset
        guard windowEnd > windowStart else { return [] }
        var result: [String] = []
        for index in entries.indices {
            let entry = entries[index]
            let top = prefixSums[index] + entry.item.topInset
            let bottom = top + entry.displayHeight
            if bottom > windowStart, top < windowEnd {
                result.append(entry.item.id)
            }
        }
        return result
    }

    // MARK: - Preservation

    func readerAnchor(offset: CGFloat) -> (id: String, distance: CGFloat)? {
        guard !entries.isEmpty else { return nil }
        let index = firstIndexWhereSlotEndExceeds(offset)
        guard index < entries.count else { return nil }
        return (id: entries[index].item.id, distance: offset - prefixSums[index])
    }

    func offset(keeping id: String, distance: CGFloat) -> CGFloat {
        let value = slotTop(of: id) + distance
        return min(max(value, 0), maxOffset)
    }

    // MARK: - Index helpers

    func index(of id: String) -> Int? { indexByID[id] }

    var ids: [String] { entries.map(\.item.id) }

    var count: Int { entries.count }

    func id(at index: Int) -> String { entries[index].item.id }

    // MARK: - Private

    private mutating func invalidate() {
        recomputePrefixSums()
        recomputeSlack()
    }

    private mutating func recomputePrefixSums() {
        var sums: [CGFloat] = [0]
        sums.reserveCapacity(entries.count + 1)
        var running: CGFloat = 0
        for entry in entries {
            running += entry.item.topInset + entry.displayHeight + entry.item.bottomInset
            sums.append(running)
        }
        prefixSums = sums
    }

    /// First index whose slot end (`prefixSums[i + 1]`) is greater than
    /// `threshold`. Doubles as `readerAnchor`'s "first item whose slot's
    /// bottom is past the offset".
    private func firstIndexWhereSlotEndExceeds(_ threshold: CGFloat) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if prefixSums[mid + 1] > threshold {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// Last index whose slot start (`prefixSums[i]`) is below `threshold`.
    private func lastIndexWhereSlotStartIsBelow(_ threshold: CGFloat) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if prefixSums[mid] >= threshold {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low - 1
    }
}
