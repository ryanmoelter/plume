import AppKit
import Observation

/// The macOS accent color, as the terminal palette slot closest to it, so an
/// accent left to the system still comes from the theme.
@Observable
final class SystemAccent {
    static let shared = SystemAccent()

    /// Nil for Graphite, which has no hue to match.
    private(set) var paletteSlot: Int?

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        paletteSlot = Self.paletteSlot(forAppleAccentColor: Self.readAppleAccentColor())
        // Posted on an accent change, after the global domain updates.
        observer = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.paletteSlot = Self.paletteSlot(forAppleAccentColor: Self.readAppleAccentColor())
            }
        }
    }

    private static func readAppleAccentColor() -> Int? {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleAccentColor"] as? Int
    }

    /// `AppleAccentColor` is absent for Multicolor, which shows blue for an
    /// app with no accent of its own, and -1 for Graphite.
    static func paletteSlot(forAppleAccentColor value: Int?) -> Int? {
        switch value {
        case -1: nil
        case 0: 1       // Red
        case 1, 2: 3    // Orange, Yellow → Yellow
        case 3: 2       // Green
        case 5, 6: 5    // Purple, Pink → Magenta
        default: 4      // Blue
        }
    }
}
