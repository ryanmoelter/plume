import Foundation
import os
import SwiftUI

extension View {
    /// Reports this item's laid-out height to `PLUME_CHAT_ITEM_STATS`.
    /// Nothing reads the measurement back into layout — it exists so the
    /// height spread that caused the hang can be watched, not corrected.
    func chatItemStatsProbe(id: String) -> some View {
        #if DEBUG
        modifier(ChatItemStatsProbe(id: id))
        #else
        self
        #endif
    }

    /// Reports the list's own width, which decides how tall every item wraps.
    func chatItemStatsViewport() -> some View {
        #if DEBUG
        modifier(ChatItemStatsViewport())
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

    /// Pieces within one window of the realized region. Twenty is a
    /// convenience, not SwiftUI's realization span, which the diagnosis
    /// leaves unknown — the global ratio is the one to watch.
    private static let window = 20

    private var order: [String] = []
    private var heights: [String: CGFloat] = [:]
    private var expanded: Set<UUID> = []
    private var viewportWidth: CGFloat = 0
    private var logger: Task<Void, Never>?

    func setOrder(_ ids: [String]) {
        let present = Set(ids)
        order = ids
        heights = heights.filter { present.contains($0.key) }
        log(reason: "load")
        startLogging()
    }

    func record(id: String, height: CGFloat) {
        heights[id] = height
    }

    func record(viewportWidth width: CGFloat) {
        viewportWidth = width
    }

    func setExpanded(_ token: UUID, _ isExpanded: Bool) {
        if isExpanded { expanded.insert(token) } else { expanded.remove(token) }
    }

    private func startLogging() {
        guard logger == nil else { return }
        logger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.log(reason: "tick")
            }
        }
    }

    private func log(reason: String) {
        let measured = order.compactMap { heights[$0] }.filter { $0 > 0 }
        guard let low = measured.min(), let high = measured.max(), low > 0 else { return }
        let sorted = measured.sorted()
        let summary = """
        chat item stats (\(reason)): pieces=\(order.count) realized=\(measured.count) \
        min=\(Int(low)) max=\(Int(high)) median=\(Int(sorted[sorted.count / 2])) \
        globalRatio=\(ratio(high / low)) windowRatio=\(ratio(windowedRatio(measured))) \
        expanded=\(expanded.count) viewportWidth=\(Int(viewportWidth))
        """
        Log.app.info("\(summary, privacy: .public)")
    }

    /// The largest max/min ratio over any window of consecutive realized
    /// pieces, which is closer to what the stack actually estimates from.
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
    let id: String

    func body(content: Content) -> some View {
        if ChatItemStats.isEnabled {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                ChatItemStats.shared.record(id: id, height: height)
            }
        } else {
            content
        }
    }
}

private struct ChatItemStatsViewport: ViewModifier {
    func body(content: Content) -> some View {
        if ChatItemStats.isEnabled {
            content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                ChatItemStats.shared.record(viewportWidth: width)
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
