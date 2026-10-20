import AppKit
import SwiftUI

/// Catches a tab chip dragged over the content area, so it can open in a
/// split.
///
/// An AppKit view rather than `onDrop`: a terminal surface is itself a drop
/// destination for text, and AppKit offers a drag to the deepest view that
/// takes it, so a SwiftUI drop region around the terminal never sees the
/// drag and the terminal pastes the chip's payload instead. Mounted only
/// while a tab drag is in flight, above every pane.
struct SplitDropCatcher: NSViewRepresentable {
    /// The drag moved to `x`; returns whether it would drop there.
    let update: (CGFloat) -> Bool
    let exit: () -> Void
    let perform: (SidebarDragItem, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.registerForDraggedTypes([.string])
        configure(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        configure(view)
    }

    private func configure(_ view: CatcherView) {
        view.update = update
        view.exit = exit
        view.perform = perform
    }

    final class CatcherView: NSView {
        var update: ((CGFloat) -> Bool)?
        var exit: (() -> Void)?
        var perform: ((SidebarDragItem, CGFloat) -> Void)?

        /// AppKit finds a drag's destination by registration, not hit
        /// testing, so clicks pass through to the panes. The catcher stays
        /// mounted for `InAppDrag`'s grace period after a cancelled drag,
        /// and refuses any drag that is neither in-app nor a tab payload.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            operation(for: sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            operation(for: sender)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            exit?()
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            exit?()
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let x = convert(sender.draggingLocation, from: nil).x
            let item = Self.isInApp(sender) ? InAppDrag.shared.takeForDrop() : Self.payload(of: sender)
            exit?()
            guard let item else { return false }
            perform?(item, x)
            return true
        }

        private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
            guard Self.isInApp(sender) || Self.payload(of: sender) != nil else { return [] }
            let x = convert(sender.draggingLocation, from: nil).x
            return update?(x) == true ? .move : []
        }

        /// A drag session Plume started. `InAppDrag` keeps its item for a
        /// grace period after the button comes up, so its item alone cannot
        /// tell a chip drag from foreign text dropped during that window.
        private static func isInApp(_ sender: any NSDraggingInfo) -> Bool {
            sender.draggingSource != nil
        }

        /// The tab a drag with no in-app source carries, as the control
        /// server's synthetic drags do.
        private static func payload(of sender: any NSDraggingInfo) -> SidebarDragItem? {
            guard let item = sender.draggingPasteboard.string(forType: .string).flatMap(SidebarDragItem.init(payload:)),
                  case .tab = item
            else { return nil }
            return item
        }
    }
}
