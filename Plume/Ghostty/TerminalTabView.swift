import GhosttyTerminal
import SwiftUI

/// Hosts one `TerminalSession`'s surface.
///
/// The session — and so the surface and its process — is owned by
/// `SurfaceManager`, not by this view. Mounting and unmounting the view never
/// creates or destroys a terminal.
struct TerminalTabView: View {
    let session: TerminalSession

    var body: some View {
        TerminalSurfaceView(context: session.state)
            .background(Color.black)
    }
}
