import AppKit
import Testing
@testable import Plume

/// The composer's effort, mode and permission dropdowns: every item shows its
/// symbol, which macOS 27 hides unless an item asks for it, and the current
/// value carries the checkmark.
@MainActor struct SymbolMenuTests {
    @Test func everyItemShowsItsSymbolAndOnlyTheSelectionIsChecked() throws {
        var chosen: [String] = []
        let options = ["low", "medium", "high"].map { title in
            SymbolMenuOption(title: title, systemImage: "gauge.with.dots.needle.50percent", isSelected: title == "medium") {
                chosen.append(title)
            }
        }
        let menu = SymbolMenu.make(title: "Effort", options: options)

        #expect(menu.items.map(\.title) == ["low", "medium", "high"])
        for item in menu.items {
            let image = try #require(item.image)
            #expect(image.isValid)
            if #available(macOS 27.0, *) { #expect(item.preferredImageVisibility == .visible) }
        }
        #expect(menu.items.map(\.state) == [.off, .on, .off])

        menu.performActionForItem(at: 2)
        #expect(chosen == ["high"])
    }

    @Test func everyComposerSymbolResolves() {
        let symbols = AgentEffort.allCases.map(\.symbol)
            + PermissionMode.allCases.map(\.symbol)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }
}
