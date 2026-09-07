import Foundation
import os
import SwiftUI

extension View {
    /// Reports this item's laid-out height to `PLUME_CHAT_ITEM_STATS`.
    /// Nothing reads the measurement back into layout — it exists so the
    /// height spread that caused the hang can be watched, not corrected.
    func chatItemStatsProbe(list: UUID, id: String, kind: @autoclosure () -> String) -> some View {
        #if DEBUG
        modifier(ChatItemStatsProbe(list: list, id: id, kind: ChatItemStats.isEnabled ? kind() : ""))
        #else
        self
        #endif
    }

    /// Reports the list's own width, which decides how tall every item wraps.
    func chatItemStatsViewport(list: UUID) -> some View {
        #if DEBUG
        modifier(ChatItemStatsViewport(list: list))
        #else
        self
        #endif
    }

    /// Counts an expanded disclosure row, which is unbounded in height and so
    /// worth knowing about when reading the stats.
    func chatItemExpansionProbe(_ isExpanded: Bool) -> some View {
        #if DEBUG
        modifier(ChatItemExpansionProbe(isExpanded: isExpanded))
        #else
        self
        #endif
    }
}

#if DEBUG
/// Measures every realized chat item and logs the spread between them.
///
/// `LazyVStack` estimates the items it has not realized from the ones it has,
/// and a wide spread within the realized set is what never settles under
/// momentum scrolling. Observational only: the numbers say whether
/// `ChatPieceSplitter`'s ceiling is doing its job.
@MainActor
final class ChatItemStats {
    static let isEnabled = ProcessInfo.processInfo.environment["PLUME_CHAT_ITEM_STATS"] != nil
    static let shared = ChatItemStats()

    /// Pieces within one window. Twenty is a convenience, not SwiftUI's
    /// realization span, which the diagnosis leaves unknown — the global
    /// ratio is the one to watch.
    private static let window = 20

    /// Per chat list. Every tab stays mounted, so several lists measure at
    /// once and one singleton's numbers would be a blend of all of them.
    private struct List {
        var order: [String] = []
        var heights: [String: CGFloat] = [:]
        var kinds: [String: String] = [:]
        var viewportWidth: CGFloat = 0
        var rebuildMilliseconds: Double = 0
    }

    private var lists: [UUID: List] = [:]
    private var expanded: Set<UUID> = []
    private var logger: Task<Void, Never>?

    func setOrder(_ ids: [String], for list: UUID) {
        let present = Set(ids)
        var entry = lists[list] ?? List()
        entry.order = ids
        entry.heights = entry.heights.filter { present.contains($0.key) }
        entry.kinds = entry.kinds.filter { present.contains($0.key) }
        lists[list] = entry
        log(list, reason: "load")
        startLogging()
    }

    func record(list: UUID, id: String, kind: String, height: CGFloat) {
        lists[list, default: List()].heights[id] = height
        lists[list]?.kinds[id] = kind
    }

    /// How long the last piece rebuild took. The lazy stack is kept so this
    /// stays flat; a regression means the splitter or cache is doing work
    /// that is not proportional to what changed.
    func record(list: UUID, rebuild: Duration) {
        let components = rebuild.components
        lists[list, default: List()].rebuildMilliseconds =
            Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    func record(list: UUID, viewportWidth: CGFloat) {
        lists[list, default: List()].viewportWidth = viewportWidth
    }

    func setExpanded(_ token: UUID, _ isExpanded: Bool) {
        if isExpanded { expanded.insert(token) } else { expanded.remove(token) }
    }

    private func startLogging() {
        guard logger == nil else { return }
        logger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                for list in self.lists.keys { self.log(list, reason: "tick") }
            }
        }
    }

    /// `measured` counts every piece ever laid out, not what is realized now
    /// — a height is never dropped. So the ratios are the worst case over
    /// the whole transcript, which is a superset of any realized window.
    private func log(_ list: UUID, reason: String) {
        guard let entry = lists[list] else { return }
        let measured = entry.order.compactMap { entry.heights[$0] }.filter { $0 > 0 }
        guard let low = measured.min(), let high = measured.max(), low > 0 else { return }
        let sorted = measured.sorted()
        let summary = """
        chat item stats (\(reason)) list=\(list.uuidString.prefix(8)): \
        pieces=\(entry.order.count) measured=\(measured.count) \
        min=\(Int(low)) max=\(Int(high)) median=\(Int(sorted[sorted.count / 2])) \
        globalRatio=\(ratio(high / low)) windowRatio=\(ratio(windowedRatio(measured))) \
        expanded=\(expanded.count) viewportWidth=\(Int(entry.viewportWidth)) \
        rebuildMs=\(ratio(CGFloat(entry.rebuildMilliseconds))) \
        tallest=[\(extremes(entry, tallest: true))] shortest=[\(extremes(entry, tallest: false))]
        """
        Log.app.info("\(summary, privacy: .public)")
    }

    /// The five pieces at either end, named by kind, so a ratio that is too
    /// wide says which block kinds are making it so.
    private func extremes(_ entry: List, tallest: Bool) -> String {
        entry.heights
            .filter { $0.value > 0 }
            .sorted { tallest ? $0.value > $1.value : $0.value < $1.value }
            .prefix(5)
            .map { "\(entry.kinds[$0.key] ?? "?"):\(Int($0.value))" }
            .joined(separator: " ")
    }

    /// The largest max/min ratio over any window of consecutive pieces, which
    /// is closer to what the stack actually estimates from.
    private func windowedRatio(_ measured: [CGFloat]) -> CGFloat {
        guard measured.count > 1 else { return 1 }
        var worst: CGFloat = 1
        for start in 0...max(0, measured.count - Self.window) {
            let slice = measured[start..<min(start + Self.window, measured.count)]
            guard let low = slice.min(), let high = slice.max(), low > 0 else { continue }
            worst = max(worst, high / low)
        }
        return worst
    }

    private func ratio(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

private struct ChatItemStatsProbe: ViewModifier {
    let list: UUID
    let id: String
    let kind: String

    func body(content: Content) -> some View {
        if ChatItemStats.isEnabled {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                ChatItemStats.shared.record(list: list, id: id, kind: kind, height: height)
            }
        } else {
            content
        }
    }
}

private struct ChatItemStatsViewport: ViewModifier {
    let list: UUID

    func body(content: Content) -> some View {
        if ChatItemStats.isEnabled {
            content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                ChatItemStats.shared.record(list: list, viewportWidth: width)
            }
        } else {
            content
        }
    }
}

private struct ChatItemExpansionProbe: ViewModifier {
    let isExpanded: Bool

    @State private var token = UUID()

    func body(content: Content) -> some View {
        if ChatItemStats.isEnabled {
            content
                .onChange(of: isExpanded, initial: true) {
                    ChatItemStats.shared.setExpanded(token, isExpanded)
                }
                .onDisappear { ChatItemStats.shared.setExpanded(token, false) }
        } else {
            content
        }
    }
}
#endif
