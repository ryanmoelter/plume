import AppKit
import SwiftUI

/// A standalone window for `UpdatePanel`, for a user-initiated Homebrew
/// check from the menu bar or Settings — neither has a sidebar row to anchor
/// a popover to. Non-modal and closable, reused if already open.
@MainActor
enum UpdatePanelWindow {
    private static var window: NSWindow?
    private static var hostingController: NSHostingController<UpdatePanelWindowContent>?

    static func show(update: AvailableUpdate) {
        if let window, let hostingController {
            hostingController.rootView = UpdatePanelWindowContent(update: update)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: UpdatePanelWindowContent(update: update))
        let panel = NSWindow(contentViewController: hosting)
        panel.title = "Plume Update"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()

        window = panel
        hostingController = hosting

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
