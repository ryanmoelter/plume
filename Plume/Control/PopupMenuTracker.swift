#if DEBUG
import AppKit

/// Remembers the menu AppKit is tracking, so the control server can read and
/// pick from a menu a click opened. A SwiftUI `Menu` builds its `NSMenu` only
/// when clicked and hands it to AppKit without exposing it.
@MainActor
final class PopupMenuTracker: NSObject {
    static let shared = PopupMenuTracker()

    private(set) var open: [NSMenu] = []
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBegin(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(didEnd(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func didBegin(_ note: Notification) {
        if let menu = note.object as? NSMenu { began(menu) }
    }

    @objc private func didEnd(_ note: Notification) {
        if let menu = note.object as? NSMenu { ended(menu) }
    }

    /// A submenu, the menu bar's included, is read through its root.
    private func began(_ menu: NSMenu) {
        guard menu !== NSApp.mainMenu, menu.supermenu == nil, !open.contains(where: { $0 === menu }) else { return }
        open.append(menu)
    }

    private func ended(_ menu: NSMenu) {
        open.removeAll { $0 === menu }
    }
}
#endif
