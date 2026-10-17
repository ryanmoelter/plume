import AppKit
import SwiftUI

/// A color the user tags a task with in the sidebar.
enum TaskColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, white, gray

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.46, green: 0.58, blue: 1.00, alpha: 1)
                : NSColor(srgbRed: 0.30, green: 0.42, blue: 1.00, alpha: 1)
        })
        case .purple: Color(red: 0.55, green: 0.38, blue: 0.98)
        case .pink: Color(red: 0.93, green: 0.25, blue: 0.70)
        case .white: .white
        case .gray: .gray
        }
    }

    /// A non-template swatch, since a menu renders SF Symbols as monochrome templates.
    var menuSwatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.fill()
            // Keeps the white swatch visible on a light menu.
            NSColor.gray.withAlphaComponent(0.5).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
