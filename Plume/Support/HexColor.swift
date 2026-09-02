import SwiftUI

/// A parsed hex color, kept as components so a caller can build a `Color`
/// without round-tripping through AppKit.
struct HexRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    /// Parses a `rrggbb`, `rgb`, or `#`-prefixed hex color string, as found in
    /// ghostty theme files. Returns nil on anything else.
    init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }

        switch digits.count {
        case 3:
            guard let value = UInt64(digits, radix: 16) else { return nil }
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
        case 6:
            guard let value = UInt64(digits, radix: 16) else { return nil }
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        default:
            return nil
        }
    }
}

extension Color {
    /// Parses a ghostty-style hex color. Returns nil on anything else —
    /// callers fall back to default chrome rather than rendering black for an
    /// unparseable value.
    init?(hex: String) {
        guard let rgb = HexRGB(hex: hex) else { return nil }
        self = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
