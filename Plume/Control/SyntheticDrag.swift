#if DEBUG
import AppKit
import UniformTypeIdentifiers

/// Drives the `NSDraggingDestination` handshake against a live view from
/// inside the process, so a drop can be exercised without a real pointer.
///
/// The window server owns the real drag session and answers only the physical
/// pointer, so there is no synthetic-event path to a drop the way there is to
/// a click. This replays the same sequence AppKit does — `draggingEntered`,
/// `draggingUpdated`, `prepareForDragOperation`, `performDragOperation`,
/// `concludeDragOperation` — and reports where it stops. A drop that only
/// fails between `draggingUpdated` and `performDragOperation` looks identical
/// to a working one from the outside, which is the class of bug this exists
/// to catch.
@MainActor
enum SyntheticDrag {
    /// The deepest view under `point` that accepts a drag carrying `types`,
    /// which is the view AppKit would negotiate with.
    static func destination(at point: NSPoint, in window: NSWindow, types: [NSPasteboard.PasteboardType]) -> NSView? {
        guard let content = window.contentView else { return nil }
        var view = content.hitTest(point)
        while let candidate = view {
            if candidate.registeredDraggedTypes.contains(where: types.contains) { return candidate }
            view = candidate.superview
        }
        return nil
    }

    /// Every type any ancestor of the hit view accepts. Reported when nothing
    /// takes the offered types, so a caller can see whether the point is
    /// registered for something else or for nothing at all.
    static func registeredTypes(at point: NSPoint, in window: NSWindow) -> [String] {
        var seen: [String] = []
        for view in hitChain(at: point, in: window) {
            seen.append(contentsOf: view.registeredDraggedTypes.map(\.rawValue))
        }
        var unique: [String] = []
        for type in seen where !unique.contains(type) { unique.append(type) }
        return unique
    }

    /// The hit view and its ancestors, innermost first. Reported alongside
    /// the types so a point that lands on an unexpected view — a terminal
    /// surface covering the pane, say — reads as that rather than as a
    /// missing registration.
    static func hitChain(at point: NSPoint, in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        var chain: [NSView] = []
        var view = content.hitTest(point)
        while let candidate = view {
            chain.append(candidate)
            view = candidate.superview
        }
        return chain
    }

    /// Runs the handshake and returns the step that ended it. Every step is
    /// reported, so a caller can tell a refusal apart from a view that was
    /// never asked.
    static func perform(_ info: SyntheticDraggingInfo, on view: NSView) -> DragOutcome {
        let entered = view.draggingEntered(info)
        guard !entered.isEmpty else {
            view.draggingExited(info)
            return DragOutcome(view: view, entered: entered, updated: nil, prepared: nil, performed: nil)
        }
        let updated = view.draggingUpdated(info)
        guard !updated.isEmpty else {
            view.draggingExited(info)
            return DragOutcome(view: view, entered: entered, updated: updated, prepared: nil, performed: nil)
        }
        let prepared = view.prepareForDragOperation(info)
        guard prepared else {
            view.draggingExited(info)
            return DragOutcome(view: view, entered: entered, updated: updated, prepared: false, performed: nil)
        }
        let performed = view.performDragOperation(info)
        if performed { view.concludeDragOperation(info) }
        return DragOutcome(view: view, entered: entered, updated: updated, prepared: true, performed: performed)
    }
}

@MainActor
struct DragOutcome {
    let view: NSView
    let entered: NSDragOperation
    let updated: NSDragOperation?
    let prepared: Bool?
    let performed: Bool?

    var succeeded: Bool { performed == true }

    /// The first step that refused, or nil when the drop landed.
    var refusedAt: String? {
        if entered.isEmpty { return "draggingEntered" }
        if updated?.isEmpty == true { return "draggingUpdated" }
        if prepared == false { return "prepareForDragOperation" }
        if performed == false { return "performDragOperation" }
        return nil
    }
}

/// A dragging session the app drives itself. `NSDraggingInfo` is a protocol,
/// so a destination cannot tell this apart from the window server's own.
@MainActor
final class SyntheticDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation
    var draggingSequenceNumber: Int = 0
    var draggingSource: Any? { nil }
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }

    init(
        pasteboard: NSPasteboard,
        location: NSPoint,
        window: NSWindow?,
        sourceOperationMask: NSDragOperation = [.copy, .move, .generic]
    ) {
        self.draggingPasteboard = pasteboard
        self.draggingLocation = location
        self.draggingDestinationWindow = window
        self.draggingSourceOperationMask = sourceOperationMask
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}

    /// A named pasteboard of its own, so a synthetic drag never disturbs the
    /// user's clipboard or the real drag pasteboard.
    static func makePasteboard(name: String = "com.ryanmoelter.Plume.syntheticDrag") -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        pasteboard.clearContents()
        return pasteboard
    }
}
#endif
