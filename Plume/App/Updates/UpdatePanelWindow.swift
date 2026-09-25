import AppKit
import SwiftUI

/// The Homebrew update window, for both the sidebar row and a user-initiated
/// check. Non-modal and closable, reused if already open.
@MainActor
enum UpdatePanelWindow {
    private static var window: NSWindow?
    private static var hostingController: NSHostingController<UpdatePanelWindowContent>?

    private static let initialHeight: CGFloat = 560
    private static let minSize = NSSize(width: 420, height: 320)

    static func show(update: AvailableUpdate) {
        if let window, let hostingController {
            hostingController.rootView = UpdatePanelWindowContent(update: update)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: UpdatePanelWindowContent(update: update))
        hosting.sizingOptions = []

        let panel = UpdatePanelNSWindow(contentViewController: hosting)
        panel.title = "Plume Update"
        panel.styleMask = [.titled, .closable, .resizable]
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = minSize
        panel.setContentSize(NSSize(width: initialWidth, height: initialHeight))
        panel.center()

        window = panel
        hostingController = hosting

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var initialWidth: CGFloat {
        Dimensions(bodySize: CGFloat(AppSettings.defaultChatFontSize)).contentWidth + UpdatePanelMetrics.padding * 2
    }
}

/// Handles ⌘W itself, which the window sees before the menu does. The
/// menu's ⌘W is Close Tab, which acts on the main window's selected tab.
private final class UpdatePanelNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
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
