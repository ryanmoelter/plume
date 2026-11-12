import AppKit
import Testing

@testable import Plume

@MainActor
struct LinearStartedProgressTests {
    @Test(arguments: [
        (1.0, [1.0], LinearStartedProgress.half),
        (1.0, [1.0, 2.0], .half),
        (2.0, [1.0, 2.0], .threeQuarters),
        (1.0, [1.0, 2.0, 3.0], .quarter),
        (2.0, [1.0, 2.0, 3.0], .half),
        (3.0, [1.0, 2.0, 3.0], .threeQuarters),
        (2.0, [1.0, 2.0, 3.0, 4.0], .half),
        (3.0, [1.0, 2.0, 3.0, 4.0], .half),
        (4.0, [1.0, 2.0, 3.0, 4.0], .threeQuarters),
        (5.0, [], .half),
    ])
    func rankPicksFill(position: Double, positions: [Double], expected: LinearStartedProgress) {
        #expect(LinearStartedProgress(position: position, among: positions) == expected)
    }

    @Test(arguments: [
        (LinearStartedProgress.quarter, "circle.lefthalf.filled.righthalf.striped.horizontal.inverse"),
        (.half, "circle.righthalf.filled"),
        (.threeQuarters, "circle.lefthalf.striped.horizontal.inverse"),
    ])
    func everyFillNamesItsRealSymbol(progress: LinearStartedProgress, expected: String) {
        let name = LinearIssueGlyph.symbolName(for: .started, progress: progress)
        #expect(name == expected)
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }
}
