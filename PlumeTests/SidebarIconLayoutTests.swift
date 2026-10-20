import AppKit
import SwiftUI
import Testing
@testable import Plume

/// The icon-plus-title layout keeps one height whichever symbol it shows, and
/// the minimum widths cover the curated icons.
@MainActor
struct SidebarIconLayoutTests {
    private func height(of icon: String?, title: String = "Title", width: CGFloat = 240) -> CGFloat {
        let view = SidebarIconTitle(
            icon: icon.map { Image(systemName: $0) },
            iconMinWidth: SidebarMetrics.taskIconMinWidth,
            spacing: 5
        ) {
            Text(title).lineLimit(nil)
        }
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @Test(arguments: ["figure.walk", "building.2.crop.circle", "pencil.and.scribble", "house.lodge"])
    func heightIgnoresTheSymbol(_ symbol: String) {
        #expect(height(of: symbol) == height(of: "star"))
        #expect(height(of: symbol) == height(of: nil))
    }

    @Test func measurementRespondsToContent() {
        let long = String(repeating: "word ", count: 40)
        #expect(height(of: "star", title: long, width: 120) > height(of: "star") * 1.5)
    }

    @Test func minimumWidthsCoverTheCuratedIcons() {
        for (size, weight, minimum) in [
            (13.0, NSFont.Weight.regular, SidebarMetrics.taskIconMinWidth),
            (11.0, .semibold, SidebarMetrics.headerIconMinWidth),
        ] {
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            for name in SidebarIcons.curated {
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
                #expect((image?.size.width ?? 0) <= minimum, "\(name) at \(size) pt")
            }
        }
    }

    @Test func wideSymbolsExceedTheMinimum() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: "house.lodge", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        #expect((image?.size.width ?? 0) > SidebarMetrics.taskIconMinWidth)
    }
}
