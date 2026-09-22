#if DEBUG
import AppKit

struct HoverRegion {
    let token: UUID
    /// Top-left content-view coordinates, like `ControlEntry.frame`.
    var frame: CGRect
    weak var window: NSWindow?
    let setHovering: (Bool) -> Void
}

/// The hover regions `plumeHover` registers, and which of them the
/// synthetic pointer is over. Nested regions hover together, as they do
/// under the real pointer.
@MainActor
final class HoverRegistry {
    static let shared = HoverRegistry()

    private var regions: [UUID: HoverRegion] = [:]
    private var hovered: Set<UUID> = []

    var count: Int { regions.count }
    var all: [HoverRegion] { Array(regions.values) }
    var hoveredCount: Int { hovered.count }

    func register(_ region: HoverRegion) {
        regions[region.token] = region
    }

    func remove(token: UUID) {
        regions[token] = nil
        hovered.remove(token)
    }

    func removeAll() {
        regions = [:]
        hovered = []
    }

    /// Moves the synthetic pointer to `point` (top-left coordinates) in
    /// `window`; regions it left hear `false`, regions it entered hear `true`.
    /// Returns how many regions are now under it.
    @discardableResult
    func pointerMoved(to point: CGPoint, in window: NSWindow) -> Int {
        let under = Set(regions.values.filter { $0.window === window && $0.frame.contains(point) }.map(\.token))
        for token in hovered.subtracting(under) { leave(token) }
        for token in under.subtracting(hovered) {
            hovered.insert(token)
            regions[token]?.setHovering(true)
        }
        return under.count
    }

    func pointerLeft(_ window: NSWindow) {
        for token in hovered where regions[token]?.window === window { leave(token) }
    }

    func pointerLeftAll() {
        for token in hovered { leave(token) }
    }

    private func leave(_ token: UUID) {
        hovered.remove(token)
        regions[token]?.setHovering(false)
    }
}
#endif
