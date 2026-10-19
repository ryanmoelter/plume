import Foundation

/// The terminal palette slot closest to the macOS accent color, which the
/// accent setting starts from on first launch.
enum SystemAccent {
    static func paletteSlot() -> Int? {
        let value = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleAccentColor"]
        return paletteSlot(forAppleAccentColor: value as? Int)
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
