import SwiftUI

extension View {
    /// Names a control for external drivers. Sets the accessibility
    /// identifier, and in a debug build also registers the control with
    /// `ControlRegistry` so the control server can find, read and drive it —
    /// one modifier, so the two can never drift apart.
    ///
    /// `label` disambiguates repeated rows; `value` is the control's current
    /// state as text; `invoke` and `setValue` let the server act on it
    /// directly instead of by synthetic click. Apply it inside `.disabled(_:)`
    /// so the registered enabled state is the real one.
    func plumeID(
        _ id: String,
        label: String? = nil,
        value: String? = nil,
        invoke: (() -> Void)? = nil,
        setValue: ((String) -> Void)? = nil
    ) -> some View {
        #if DEBUG
        modifier(PlumeIDModifier(id: id, label: label, value: value, invoke: invoke, setValue: setValue))
        #else
        accessibilityIdentifier(id)
        #endif
    }

    /// Marks a subtree as off screen for the control server, for a container
    /// that hides content by opacity rather than unmounting it.
    func plumeControlsHidden(_ hidden: Bool) -> some View {
        environment(\.plumeControlsHidden, hidden)
    }
}

extension EnvironmentValues {
    @Entry var plumeControlsHidden = false
}

#if DEBUG
private struct PlumeIDModifier: ViewModifier {
    let id: String
    let label: String?
    let value: String?
    let invoke: (() -> Void)?
    let setValue: ((String) -> Void)?

    @State private var registration = ViewRegistration()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.plumeControlsHidden) private var isHidden

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
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
                ControlRegistry.shared.remove(token: registration.token)
            }
            .onChange(of: [id, label ?? "", value ?? "", String(isEnabled), String(isHidden)]) { sync() }
    }

    /// Geometry and window arrive before `onAppear`, and in either order, so
    /// every callback writes the whole entry from what is known so far.
    private func sync() {
        guard registration.isMounted, !isHidden else {
            ControlRegistry.shared.remove(token: registration.token)
            return
        }
        ControlRegistry.shared.register(ControlEntry(
            token: registration.token, id: id, label: label, value: value, isEnabled: isEnabled,
            frame: WindowGeometry.contentRect(fromGlobal: registration.frame, in: registration.window), window: registration.window, invoke: invoke, setValue: setValue
        ))
    }
}

/// What a self-registering modifier knows about its view so far. Geometry
/// and window arrive before `onAppear`, and in either order.
@MainActor
final class ViewRegistration {
    let token = UUID()
    var frame = CGRect.zero
    weak var window: NSWindow?
    var isMounted = false
}

/// Reports the window a SwiftUI view landed in, which nothing in SwiftUI
/// exposes. Inert: it draws nothing and takes no hits.
struct WindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
