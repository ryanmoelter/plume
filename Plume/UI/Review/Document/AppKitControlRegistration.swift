#if DEBUG
import AppKit

/// `plumeID` for an AppKit view: registers it with the control server while
/// it is in a window, at wherever it is when a driver asks.
@MainActor
final class AppKitControlRegistration {
    private let token = UUID()
    private weak var view: NSView?
    private var id: String?
    private var label: String?
    private var value: String?
    private var invoke: (() -> Void)?

    init(view: NSView) {
        self.view = view
    }

    func set(id: String, label: String?, value: String? = nil, invoke: (() -> Void)?) {
        self.id = id
        self.label = label
        self.value = value
        self.invoke = invoke
        sync()
    }

    func clear() {
        id = nil
        sync()
    }

    /// Call from `viewDidMoveToWindow`.
    func sync() {
        guard let id, let view, let window = view.window else {
            ControlRegistry.shared.remove(token: token)
            return
        }
        ControlRegistry.shared.register(ControlEntry(
            token: token, id: id, label: label, value: value, isEnabled: true,
            frame: Self.contentFrame(of: view), window: window, invoke: invoke, setValue: nil,
            liveFrame: { [weak view] in view.map(Self.contentFrame(of:)) ?? .zero }
        ))
    }

    /// The part of `view` its scroll view shows, in top-left content-view
    /// coordinates.
    static func contentFrame(of view: NSView) -> CGRect {
        guard let content = view.window?.contentView else { return .zero }
        let visible = view.visibleRect
        guard !visible.isEmpty else { return .zero }
        let rect = view.convert(visible, to: content)
        return content.isFlipped ? rect : WindowGeometry.topLeftRect(fromAppKit: rect, contentHeight: content.bounds.height)
    }
}
#endif
