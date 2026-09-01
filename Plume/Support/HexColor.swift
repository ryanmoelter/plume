import SwiftUI

extension Color {
    /// Parses a `rrggbb`, `rgb`, or `#`-prefixed hex color string, as found in
    /// ghostty theme files. Returns nil on anything else — callers fall back
    /// to default chrome rather than rendering black for an unparseable value.
    init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }

        let value: UInt64
        let (r, g, b): (Double, Double, Double)
        switch digits.count {
        case 3:
            guard let parsed = UInt64(digits, radix: 16) else { return nil }
            value = parsed
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
        case 6:
            guard let parsed = UInt64(digits, radix: 16) else { return nil }
            value = parsed
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            return nil
        }

        self = Color(red: r, green: g, blue: b)
    }
}
