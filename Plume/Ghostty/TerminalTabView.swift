import GhosttyTerminal
import SwiftUI

/// Hosts one `TerminalSession`'s surface.
///
/// The session — and so the surface and its process — is owned by
/// `SurfaceManager`, not by this view. Mounting and unmounting the view never
/// creates or destroys a terminal.
struct TerminalTabView: View {
    let session: TerminalSession
    /// Identifies the tab for bell marking and notification routing. Nil
    /// where a caller has no tab context, which only skips those.
    var taskID: UUID?
    var tabID: UUID?
    /// Whether this tab is the one on screen. Hidden tabs stay mounted at
    /// zero opacity, so without this every one of them keeps drawing frames
    /// nobody sees.
    var isVisible = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TerminalSurfaceView(context: session.state)
            // Shows through wherever the surface doesn't reach — around the
            // window padding, and while a surface is still starting up.
            .background(ThemeChrome.background(for: colorScheme) ?? Color.black)
            // Never in `body`: writing observable state during a render makes
            // the render invalidate itself.
            .onChange(of: isVisible, initial: true) { _, visible in
                session.state.isSurfaceVisible = visible
                if visible {
                    session.state.requestFocus()
                    markBellSeen()
                }
            }
            .onChange(of: session.bellCount) { previous, current in
                guard current > previous else { return }
                handleBell()
            }
            .onChange(of: session.desktopNotification) { _, notification in
                guard let notification else { return }
                postDesktopNotification(notification)
            }
    }

    private func markBellSeen() {
        guard let tabID else { return }
        BellStore.shared.markSeen(tabID: tabID)
    }

    private func handleBell() {
        guard let tabID, let taskID else { return }
        let onScreen = NotificationSuppression.isOnScreen(
            tabID: tabID, taskID: taskID, audience: Notifier.shared.audience()
        )
        BellStore.shared.recordBell(tabID: tabID, isOnScreen: onScreen)
        guard !onScreen else { return }

        Notifier.shared.post(.init(
            taskID: taskID,
            tabID: tabID,
            title: TitleStore.shared.title(forTab: tabID) ?? session.displayTitle,
            body: "The terminal rang a bell.",
            dedupeKey: "bell-\(tabID.uuidString)"
        ))
    }

    /// OSC 9 / OSC 777 is the program asking for a desktop notification by
    /// name, so it carries its own title and body and is never suppressed by
    /// a bell's rules — but it is still redundant when the user is watching.
    private func postDesktopNotification(_ notification: TerminalSession.DesktopNotification) {
        guard let tabID, let taskID else { return }
        Notifier.shared.notifyIfUnseen(.init(
            taskID: taskID,
            tabID: tabID,
            title: notification.title.isEmpty ? session.displayTitle : notification.title,
            body: notification.body,
            dedupeKey: "osc-\(tabID.uuidString)"
        ))
    }
}
