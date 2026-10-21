import SwiftUI

/// Maps a Linear workflow state's own color onto the terminal theme, so state
/// glyphs share the palette, and its contrast, instead of Linear's fixed hues.
nonisolated enum LinearStateColor {
    /// The ANSI hues a state can take: red, green, yellow, blue, magenta, cyan.
    static let slots = [1, 2, 3, 4, 5, 6]

    /// Below this OKLCH chroma a state color reads as gray, and draws in the
    /// text color rather than in whichever hue happens to be nearest.
    static let neutralChroma = 0.04

    /// For a theme with no palette, roughly the system colors' hues.
    static let fallbackSlots: [Int: HexRGB] = [
        1: HexRGB(red: 1, green: 0.23, blue: 0.19),
        2: HexRGB(red: 0.2, green: 0.78, blue: 0.35),
        3: HexRGB(red: 1, green: 0.8, blue: 0),
        4: HexRGB(red: 0, green: 0.48, blue: 1),
        5: HexRGB(red: 0.69, green: 0.32, blue: 0.87),
        6: HexRGB(red: 0.35, green: 0.78, blue: 0.98),
    ]

    /// The candidate slot nearest the color, or nil when it is neutral.
    static func nearestSlot(to color: HexRGB, among candidates: [Int: HexRGB]) -> Int? {
        let target = OKLab(color)
        guard target.chroma >= neutralChroma else { return nil }
        return candidates
            .filter { OKLab($0.value).chroma >= neutralChroma }
            .min { target.distance(to: OKLab($0.value)) < target.distance(to: OKLab($1.value)) }?
            .key
    }

    struct OKLab {
        let l: Double
        let a: Double
        let b: Double

        init(_ rgb: HexRGB) {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let (r, g, bl) = (linear(rgb.red), linear(rgb.green), linear(rgb.blue))
            let lms = (
                cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl),
                cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl),
                cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
            )
            l = 0.2104542553 * lms.0 + 0.7936177850 * lms.1 - 0.0040720468 * lms.2
            a = 1.9779984951 * lms.0 - 2.4285922050 * lms.1 + 0.4505937099 * lms.2
            b = 0.0259040371 * lms.0 + 0.7827717662 * lms.1 - 0.8086757660 * lms.2
        }

        var chroma: Double { (a * a + b * b).squareRoot() }

        /// Lightness counts for half, since a theme tunes its palette's
        /// lightness to its background and the hue is what carries meaning.
        func distance(to other: OKLab) -> Double {
            let dl = (l - other.l) * 0.5
            return (dl * dl + (a - other.a) * (a - other.a) + (b - other.b) * (b - other.b)).squareRoot()
        }
    }
}
