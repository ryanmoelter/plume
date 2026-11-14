import AppKit
import SwiftUI

/// One item of a `SymbolMenuButton`'s menu.
struct SymbolMenuOption {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void
}

/// A composer segment's dropdown, laid over the segment's own label.
///
/// An AppKit menu rather than a SwiftUI `Menu` so every item shows its
/// symbol: SwiftUI builds its items with automatic image visibility, which
/// macOS 27 resolves to hidden, and offers no way to ask otherwise.
struct SymbolMenuButton: NSViewRepresentable {
    let title: String
    let value: String
    let options: [SymbolMenuOption]
    /// A disabled line after the options, saying why some are disabled.
    var footnote: String?

    func makeNSView(context: Context) -> SymbolMenuPopupButton {
        let button = SymbolMenuPopupButton()
        button.isBordered = false
        button.title = ""
        button.target = button
        button.action = #selector(SymbolMenuPopupButton.showMenu)
        return button
    }

    func updateNSView(_ button: SymbolMenuPopupButton, context: Context) {
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(value)
        button.makeMenu = { [title, options, footnote] in SymbolMenu.make(title: title, options: options, footnote: footnote) }
    }
}

final class SymbolMenuPopupButton: NSButton {
    var makeMenu: (() -> NSMenu)?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    // The SwiftUI segment beneath this button supplies all its appearance.
    override func draw(_ dirtyRect: NSRect) {}

    @objc func showMenu() {
        guard window != nil, let menu = makeMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
    }
}

@MainActor enum SymbolMenu {
    static func make(title: String, options: [SymbolMenuOption], footnote: String? = nil) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for option in options {
            let item = SymbolMenuItem(title: option.title, perform: option.action)
            item.image = NSImage(systemSymbolName: option.systemImage, accessibilityDescription: nil)
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            item.state = option.isSelected ? .on : .off
            item.isEnabled = option.isEnabled
            menu.addItem(item)
        }
        if let footnote {
            let item = NSMenuItem(title: footnote, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }
}

// Nonisolated so the stubs Swift synthesizes for NSMenuItem's other designated
// initializers match the nonisolated originals.
private nonisolated final class SymbolMenuItem: NSMenuItem {
    private let perform: () -> Void

    @MainActor init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor @objc private func invoke() { perform() }
}
