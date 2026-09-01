import GhosttyTerminal
import SwiftUI

/// Hosts one `TerminalSession`'s surface.
///
/// The session — and so the surface and its process — is owned by
/// `SurfaceManager`, not by this view. Mounting and unmounting the view never
/// creates or destroys a terminal.
struct TerminalTabView: View {
    let session: TerminalSession
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
                }
            }
    }
}
