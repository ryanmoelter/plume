import AppKit

/// Turns mouse events over the transcript's text into a selection.
///
/// A local monitor rather than the rows' own handling, because a drag runs
/// across many hosting views and the rows it crosses come and go. A plain
/// click passes through untouched, so a link under it still opens and the
/// composer keeps the keyboard. Only a drag past `dragThreshold`, a double
/// or triple click, or a shift-click takes the events and the first
/// responder, which happens before any tracking starts (PLUME-106).
@MainActor
final class ChatSelectionTracker {
    private weak var controller: ChatListController?
    private var monitor: Any?
    private var pending: (point: NSPoint, position: ChatTextPosition)?
    private var isDragging = false
    private var lastDragPoint: NSPoint?
    private var autoscrollTimer: Timer?

    private static let dragThreshold: CGFloat = 3

    init(controller: ChatListController) {
        self.controller = controller
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func tearDown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stopAutoscroll()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let controller, let window = controller.scrollView.window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown: return mouseDown(event, controller: controller)
        case .leftMouseDragged: return mouseDragged(event, controller: controller)
        case .leftMouseUp: return mouseUp(event)
        case .rightMouseDown: return rightMouseDown(event, controller: controller)
        default: return event
        }
    }

    private func mouseDown(_ event: NSEvent, controller: ChatListController) -> NSEvent? {
        pending = nil
        isDragging = false
        guard controller.isInDocument(event.locationInWindow) else { return event }
        let store = controller.selection
        // Rows that keep SwiftUI's own selection run a tracking loop that
        // hides the mouse-up from this monitor, so they are never tracked.
        guard let position = controller.selectionPosition(onTextAt: event.locationInWindow) else {
            store.set(nil)
            return event
        }
        if event.modifierFlags.contains(.shift), let selection = store.selection {
            store.set(selection.extended(to: position))
            beginTracking(controller)
            return nil
        }
        switch event.clickCount {
        case 1:
            store.set(nil)
            pending = (event.locationInWindow, position)
            return event
        case 2:
            // Swallowed even over a link, which would otherwise open twice.
            guard let text = controller.selectableText(of: position.pieceID),
                  let word = ChatSelection.expandToWord(at: position, in: text) else { return nil }
            store.set(word)
        default:
            store.set(.expandToPiece(position.pieceID, length: store.length(of: position.pieceID)))
        }
        beginTracking(controller)
        return nil
    }

    private func mouseDragged(_ event: NSEvent, controller: ChatListController) -> NSEvent? {
        if !isDragging {
            guard let pending else { return event }
            let point = event.locationInWindow
            guard hypot(point.x - pending.point.x, point.y - pending.point.y) > Self.dragThreshold else { return event }
            controller.selection.set(ChatSelection(anchor: pending.position, focus: pending.position))
            self.pending = nil
            beginTracking(controller)
        }
        extend(to: event.locationInWindow, controller: controller)
        return nil
    }

    private func mouseUp(_ event: NSEvent) -> NSEvent? {
        pending = nil
        guard isDragging else { return event }
        isDragging = false
        lastDragPoint = nil
        stopAutoscroll()
        return nil
    }

    /// Opens Copy and Copy as Plain Text over the selection, selecting the
    /// word under the pointer first when nothing is selected.
    private func rightMouseDown(_ event: NSEvent, controller: ChatListController) -> NSEvent? {
        guard controller.isInDocument(event.locationInWindow),
              let position = controller.selectionPosition(onTextAt: event.locationInWindow) else { return event }
        let store = controller.selection
        if !store.hasSelection {
            guard let text = controller.selectableText(of: position.pieceID),
                  let word = ChatSelection.expandToWord(at: position, in: text) else { return event }
            store.set(word)
        }
        controller.takeSelectionFocus()
        NSMenu.popUpContextMenu(controller.documentView.selectionMenu(), with: event, for: controller.documentView)
        return nil
    }

    private func beginTracking(_ controller: ChatListController) {
        isDragging = true
        controller.takeSelectionFocus()
    }

    private func extend(to point: NSPoint, controller: ChatListController) {
        lastDragPoint = point
        if let selection = controller.selection.selection,
           let focus = controller.selectionPosition(nearest: point) {
            controller.selection.set(selection.extended(to: focus))
        }
        if controller.autoscrollDelta(for: point) == 0 {
            stopAutoscroll()
        } else if autoscrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscroll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoscrollTimer = timer
        }
    }

    private func autoscroll() {
        guard isDragging, let controller, let point = lastDragPoint else { return stopAutoscroll() }
        controller.autoscroll(by: controller.autoscrollDelta(for: point))
        extend(to: point, controller: controller)
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }
}
