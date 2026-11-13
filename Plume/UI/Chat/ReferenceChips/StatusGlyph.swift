import AppKit
import SwiftUI

/// A state mark: an SF Symbol, or a Linear started state's hand-drawn pie.
nonisolated enum StatusGlyph: Hashable, Sendable {
    case symbol(String)
    case linearProgress(LinearStartedProgress)

    /// An image tinted `color` for the caller to fit into a `side`-point
    /// square. A symbol's comes out larger than the square.
    @MainActor
    func image(side: CGFloat, color: NSColor) -> NSImage? {
        switch self {
        case .symbol(let name):
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        case .linearProgress(let progress):
            LinearProgressGlyph.image(progress: progress, side: side, color: color)
        }
    }
}

/// Takes the foreground style, like an `Image(systemName:)`.
struct StatusGlyphView: View {
    let glyph: StatusGlyph

    init(_ glyph: StatusGlyph) {
        self.glyph = glyph
    }

    var body: some View {
        switch glyph {
        case .symbol(let name): Image(systemName: name)
        case .linearProgress(let progress): LinearProgressGlyph(progress: progress)
        }
    }
}
