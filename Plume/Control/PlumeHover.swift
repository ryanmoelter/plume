import SwiftUI

extension View {
    /// `onHover` that the debug control server can drive. SwiftUI's own
    /// hover tracking answers only the real pointer — no synthetic event
    /// reaches it — so in a debug build the region also registers with
    /// `HoverRegistry`, and the server's `hover` command calls `action`
    /// itself. Use this everywhere in place of `.onHover`.
    func plumeHover(perform action: @escaping (Bool) -> Void) -> some View {
        #if DEBUG
        modifier(PlumeHoverModifier(action: action))
        #else
        onHover(perform: action)
        #endif
    }
}

#if DEBUG
private struct PlumeHoverModifier: ViewModifier {
    let action: (Bool) -> Void

    @State private var registration = ViewRegistration()
    @Environment(\.plumeControlsHidden) private var isHidden

    func body(content: Content) -> some View {
        content
            .onHover(perform: action)
            .background {
                WindowProbe { window in
                    registration.window = window
                    sync()
                }
                .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                registration.frame = frame
                registration.isMounted = true
                sync()
            }
            .onAppear {
                registration.isMounted = true
                sync()
            }
            .onDisappear {
                registration.isMounted = false
                HoverRegistry.shared.remove(token: registration.token)
            }
            .onChange(of: isHidden) { sync() }
    }

    private func sync() {
        guard registration.isMounted, !isHidden else {
            HoverRegistry.shared.remove(token: registration.token)
            return
        }
        HoverRegistry.shared.register(HoverRegion(
            token: registration.token, frame: WindowGeometry.contentRect(fromGlobal: registration.frame, in: registration.window), window: registration.window, setHovering: action
        ))
    }
}
#endif
