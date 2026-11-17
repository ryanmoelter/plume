import AppKit
import SwiftUI

/// The measured widths the window's floor and the sidebar's ceiling are
/// derived from.
@Observable
final class WindowColumnWidths {
    /// Starts generous so the sidebar's ceiling is unclamped until the first
    /// real measurement lands.
    var window: CGFloat = .infinity
    var sidebar: CGFloat = WindowMetrics.sidebarIdealWidth
}

/// The window's minimum size for the selected task. A modifier of its own so
/// only it, not the window's root, depends on the task's panes.
struct WindowFloor: ViewModifier {
    let task: WorkTask?
    let sidebarVisible: Bool
    let widths: WindowColumnWidths

    func body(content: Content) -> some View {
        content.frame(
            minWidth: WindowMetrics.minimumWidth(
                sidebarVisible: sidebarVisible,
                paneCount: task?.paneCount ?? 1,
                sidebarWidth: widths.sidebar
            ),
            minHeight: WindowMetrics.minimumHeight
        )
    }
}

/// The sidebar column's width bounds, measuring the width it ends up at.
struct SidebarColumnWidth: ViewModifier {
    let task: WorkTask?
    let widths: WindowColumnWidths
    @State private var divider = SidebarDivider()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // A collapsed sidebar measures nothing; keep the width it
                // comes back at.
                if width > 0 { widths.sidebar = width }
            }
            .background(SidebarDividerBehavior(divider: divider))
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 6)
                    .allowsHitTesting(false)
                    .plumeID(
                        AccessibilityID.sidebarResizeHandle,
                        value: "\(Int(widths.sidebar))",
                        invoke: { divider.setWidth(WindowMetrics.sidebarIdealWidth) },
                        setValue: { text in Double(text).map { divider.setWidth(CGFloat($0)) } }
                    )
            }
            .navigationSplitViewColumnWidth(
                min: WindowMetrics.sidebarMinimumWidth,
                ideal: WindowMetrics.sidebarIdealWidth,
                max: WindowMetrics.sidebarMaximumWidth(
                    windowWidth: widths.window,
                    paneCount: task?.paneCount ?? 1,
                    sidebarWidth: widths.sidebar
                )
            )
    }
}

/// Replaces the split view's double-click on the divider, which maximizes the
/// sidebar, with a reset to its ideal width. Also registers the divider for
/// the debug control server, which can't double-click.
fileprivate struct SidebarDividerBehavior: NSViewRepresentable {
    let divider: SidebarDivider

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        divider.view = view
        return view
    }
    func updateNSView(_ view: DividerView, context: Context) {}

    final class DividerView: NSView {
        private var monitor: Any?
        private static let grabWidth: CGFloat = 8

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        private var splitView: NSSplitView? {
            window?.contentView?.firstDescendant(ofType: NSSplitView.self)
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.clickCount == 2, event.window === window,
                  let split = splitView, let sidebar = split.arrangedSubviews.first,
                  sidebar.frame.width > 0
            else { return false }
            let point = split.convert(event.locationInWindow, from: nil)
            let edge = sidebar.frame.maxX
            guard split.bounds.contains(point),
                  abs(point.x - edge) <= Self.grabWidth / 2 + split.dividerThickness / 2
            else { return false }
            resetWidth()
            return true
        }

        func setWidth(_ width: CGFloat) {
            splitView?.setPosition(WindowMetrics.clampedSidebarWidth(width), ofDividerAt: 0)
        }

        func resetWidth() { setWidth(WindowMetrics.sidebarIdealWidth) }
    }
}

final class SidebarDivider {
    fileprivate weak var view: SidebarDividerBehavior.DividerView?

    func setWidth(_ width: CGFloat) { view?.setWidth(width) }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
