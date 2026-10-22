import GhosttyTerminal
import SwiftUI

/// Hosts one `TerminalSession`'s surface.
///
/// The session — and so the surface and its process — is owned by
/// `SurfaceManager`, not by this view. Mounting and unmounting the view never
/// creates or destroys a terminal.
struct TerminalTabView: View {
    let session: TerminalSession
    /// Identifies the tab for clearing its bell mark. Nil where a caller has
    /// no tab context, which only skips that.
    var tabID: UUID?
    /// Whether this tab is on screen. Hidden tabs stay mounted at zero
    /// opacity, so without this every one of them keeps drawing frames
    /// nobody sees.
    var isVisible = true
    /// Whether this tab takes first responder — the visible tab, or the
    /// focused pane of a split.
    var isFocused = true
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
                guard visible else { return }
                markBellSeen()
            }
            .claimsPaneFocus(isVisible: isVisible, isFocused: isFocused) {
                session.state.requestFocus()
            }
    }

    private func markBellSeen() {
        guard let tabID else { return }
        BellStore.shared.markSeen(tabID: tabID)
        Notifier.shared.dismiss(tabID: tabID)
    }
}
