import AppKit
import SwiftUI

/// The Homebrew update window, for both the sidebar row and a user-initiated
/// check. Non-modal and closable, reused if already open.
@MainActor
enum UpdatePanelWindow {
    private static var window: NSWindow?
    private static var hostingController: NSHostingController<UpdatePanelWindowContent>?

    private static let minHeight: CGFloat = 280
    private static let maxHeightFraction: CGFloat = 0.7

    static func show(update: AvailableUpdate) {
        if let window, let hostingController {
            hostingController.rootView = UpdatePanelWindowContent(update: update)
            window.setContentSize(NSSize(width: windowWidth, height: idealHeight(for: update)))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: UpdatePanelWindowContent(update: update))

        let panel = NSWindow(contentViewController: hosting)
        panel.title = "Plume Update"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.isReleasedWhenClosed = false

        panel.minSize = NSSize(width: windowWidth, height: minHeight)
        panel.maxSize = NSSize(width: .greatestFiniteMagnitude, height: maxHeight)
        panel.setContentSize(NSSize(width: windowWidth, height: idealHeight(for: update)))
        panel.center()

        window = panel
        hostingController = hosting

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var windowWidth: CGFloat {
        Dimensions(bodySize: CGFloat(AppSettings.defaultChatFontSize)).contentWidth + UpdatePanelMetrics.padding * 2
    }

    private static var maxHeight: CGFloat {
        (NSScreen.main.map { $0.visibleFrame.height * maxHeightFraction }) ?? 800
    }

    /// Measured off-window rather than through
    /// `sizingOptions = [.preferredContentSize]`, which raises in
    /// `_postWindowNeedsUpdateConstraints` against the panel's `ScrollView`.
    private static func idealHeight(for update: AvailableUpdate) -> CGFloat {
        let hostingView = NSHostingView(
            rootView: UpdatePanelMeasurementContent(update: update)
                .frame(width: windowWidth)
        )
        hostingView.sizingOptions = .intrinsicContentSize
        let height = hostingView.fittingSize.height
        return min(max(height, minHeight), maxHeight)
    }
}

/// `UpdatePanel`, themed by hand: a plain `NSHostingController` root
/// inherits none of the SwiftUI environment a normally mounted view gets.
private struct UpdatePanelWindowContent: View {
    let update: AvailableUpdate

    var body: some View {
        UpdatePanel(update: update)
            .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
    }
}

/// `UpdatePanelContent` without the scrolling, for measuring the window's
/// ideal height.
private struct UpdatePanelMeasurementContent: View {
    let update: AvailableUpdate

    var body: some View {
        UpdatePanelContent(update: update)
            .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
    }
}
