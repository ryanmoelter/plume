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
            // The theme may have been reloaded since the window was built.
            AppDelegate.tintTitlebar(of: window)
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
        AppDelegate.tintTitlebar(of: panel)
        panel.setContentSize(NSSize(width: initialWidth, height: initialHeight))
        panel.center()

        window = panel
        hostingController = hosting

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var initialWidth: CGFloat {
        let dimensions = Dimensions(bodySize: CGFloat(AppSettings.defaultChatFontSize))
        return dimensions.contentWidth + dimensions.horizontalEdgePadding * 2
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
/// Follows `availableUpdate` so a refresh behind the open window shows the
/// newest release, and keeps what it opened with if a refresh clears it.
private struct UpdatePanelWindowContent: View {
    let update: AvailableUpdate
    @State private var updates = UpdateController.shared

    var body: some View {
        UpdatePanel(update: updates.availableUpdate ?? update)
            .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
    }
}
