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

    /// Registers an item of the `Menu` this modifies. A menu mounts its items only while it is open, so a `plumeID` inside one never registers. The entry has the menu's frame, so it answers `invoke` and not `click`. Pass the condition the menu builds the item under as `isPresent`.
    func plumeMenuItem(
        _ id: String,
        label: String? = nil,
        isPresent: Bool = true,
        isEnabled: Bool = true,
        invoke: @escaping () -> Void
    ) -> some View {
        #if DEBUG
        background {
            if isPresent {
                Color.clear.plumeID(id, label: label, invoke: invoke).disabled(!isEnabled)
            }
        }
        #else
        self
        #endif
    }

    /// `plumeMenuItem` for each of a `Menu`'s repeated items, all under one
    /// id and told apart by `label`.
    func plumeMenuItems<Item: Hashable>(
        _ id: String,
        _ items: [Item],
        label: @escaping (Item) -> String,
        invoke: @escaping (Item) -> Void
    ) -> some View {
        #if DEBUG
        background {
            ForEach(items, id: \.self) { item in
                Color.clear.plumeID(id, label: label(item), invoke: { invoke(item) })
            }
        }
        #else
        self
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
        registration.invoke = invoke
        registration.setValue = setValue
        return content
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
            .onChange(of: [id, label ?? "", value ?? "", String(isEnabled), String(isHidden), String(invoke != nil), String(setValue != nil)]) { sync() }
    }

    /// Geometry and window arrive before `onAppear`, and in either order, so
    /// every callback writes the whole entry from what is known so far.
    private func sync() {
        guard registration.isMounted, !isHidden else {
            ControlRegistry.shared.remove(token: registration.token)
            return
        }
        let registration = registration
        ControlRegistry.shared.register(ControlEntry(
            token: registration.token, id: id, label: label, value: value, isEnabled: isEnabled,
            frame: WindowGeometry.contentRect(fromGlobal: registration.frame, in: registration.window), window: registration.window,
            invoke: invoke == nil ? nil : { registration.invoke?() },
            setValue: setValue == nil ? nil : { registration.setValue?($0) }
        ))
    }
}

/// What a self-registering modifier knows about its view so far. Geometry
/// and window arrive before `onAppear`, and in either order.
///
/// `invoke`, `setValue` and `hover` are rewritten on every body evaluation,
/// and the registered entry calls through them, because a view can re-render
/// with new captured state (another task's tab strip, say) without any
/// `sync()` trigger firing. Not observable, so writing them during `body`
/// invalidates nothing.
@MainActor
final class ViewRegistration {
    let token = UUID()
    var frame = CGRect.zero
    weak var window: NSWindow?
    var isMounted = false
    var invoke: (() -> Void)?
    var setValue: ((String) -> Void)?
    var hover: ((Bool) -> Void)?
}
#endif

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
