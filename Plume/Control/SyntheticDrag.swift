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
    /// The view AppKit would negotiate with: the one accepting `types` whose
    /// frame contains `point`. Frontmost wins, which for siblings is the last
    /// one added — the order AppKit's own search uses.
    ///
    /// Registration is not hit-testing. SwiftUI puts its drop destinations
    /// *behind* the content they belong to, so `hitTest` lands on the drawing
    /// view and never reaches them.
    static func destination(at point: NSPoint, in window: NSWindow, types: [NSPasteboard.PasteboardType]) -> NSView? {
        allDestinations(in: window)
            .last { view, _ in
                accepts(view, types) && view.convert(view.bounds, to: nil).contains(point)
            }?
            .view
    }

    /// Registration is by conformance, not string equality: SwiftUI registers
    /// `public.data`/`public.item`, which a `public.utf8-plain-text` drag
    /// satisfies. Matching literally finds none of SwiftUI's destinations.
    private static func accepts(_ view: NSView, _ offered: [NSPasteboard.PasteboardType]) -> Bool {
        let registered = view.registeredDraggedTypes.compactMap { UTType($0.rawValue) }
        return offered.contains { type in
            guard let offeredType = UTType(type.rawValue) else { return false }
            return registered.contains { offeredType.conforms(to: $0) }
        }
    }

    /// Every view in the window that accepts a drag, innermost first, with
    /// its frame. A drop that silently does nothing is usually a destination
    /// that was never created, and this is how that shows up.
    static func allDestinations(in window: NSWindow) -> [(view: NSView, types: [String])] {
        guard let content = window.contentView else { return [] }
        var out: [(NSView, [String])] = []
        func visit(_ view: NSView) {
            let types = view.registeredDraggedTypes.map(\.rawValue)
            if !types.isEmpty { out.append((view, types)) }
            view.subviews.forEach(visit)
        }
        visit(content)
        return out
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

    /// The real drag pasteboard, because a destination may read it by name
    /// rather than through `draggingPasteboard` — `DropInfo` does. It is not
    /// the user's clipboard, so a synthetic drag leaves that alone.
    static func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        return pasteboard
    }
}
#endif
