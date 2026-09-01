import GhosttyTerminal
import SwiftUI

/// Hosts one `TerminalSession`'s surface.
///
/// The session — and so the surface and its process — is owned by
/// `SurfaceManager`, not by this view. Mounting and unmounting the view never
/// creates or destroys a terminal.
struct TerminalTabView: View {
    let session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TerminalSurfaceView(context: session.state)
            // Shows through wherever the surface doesn't reach — around the
            // window padding, and while a surface is still starting up.
            .background(ThemeChrome.background(for: colorScheme) ?? Color.black)
    }
}
