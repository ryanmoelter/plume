import AppKit
import SwiftUI

/// One row's actions, drawn both as SwiftUI menu items and as the AppKit
/// menu a row click pops up.
enum RowMenu {
    enum Entry {
        /// The second string is the item's `plumeMenuItem` ID.
        case action(String, String, isEnabled: Bool, perform: () -> Void)
        case divider
    }

    /// For a row whose click shows its menu rather than opening anything.
    @MainActor static func popUp(_ entries: [Entry]) {
        // At the click rather than the pointer, which a synthetic click
        // never moves.
        let click = NSApp.currentEvent.flatMap { event in
            event.window?.contentView.map { ($0, $0.convert(event.locationInWindow, from: nil)) }
        }
        // After the click's own event handling, which a modal menu
        // tracking loop would otherwise run inside.
        Task { @MainActor in
            if let (view, point) = click {
                make(entries).popUp(positioning: nil, at: point, in: view)
            } else {
                make(entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
        }
    }

    @MainActor static func make(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider:
                menu.addItem(.separator())
            case .action(let title, _, let isEnabled, let perform):
                let item = ClosureMenuItem(title: title, perform: perform)
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }
        return menu
    }
}

struct RowMenuItems: View {
    let entries: [RowMenu.Entry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .divider:
                Divider()
            case .action(let title, _, let isEnabled, let perform):
                Button(title, action: perform)
                    .disabled(!isEnabled)
            }
        }
    }
}

/// Registers each action with the control server, under the row's label.
struct RowMenuItemRegistrations: View {
    let entries: [RowMenu.Entry]
    let label: String

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            if case .action(_, let id, let isEnabled, let perform) = entry {
                Color.clear.plumeMenuItem(id, label: label, isEnabled: isEnabled, invoke: perform)
            }
        }
    }
}

// Nonisolated so the stubs Swift synthesizes for NSMenuItem's other designated
// initializers match the nonisolated originals.
private nonisolated final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void

    @MainActor init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor @objc private func invoke() { perform() }
}
