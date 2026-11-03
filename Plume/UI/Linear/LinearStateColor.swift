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

    /// The candidate nearest the color, or nil when it is neutral.
    static func nearest<Key: Hashable>(to color: HexRGB, among candidates: [Key: HexRGB]) -> Key? {
        let target = OKLab(color)
        guard target.chroma >= neutralChroma else { return nil }
        return candidates
            .filter { OKLab($0.value).chroma >= neutralChroma }
            .min { target.distance(to: OKLab($0.value)) < target.distance(to: OKLab($1.value)) }?
            .key
    }

    /// Keeps the color's hue and chroma, and moves its OKLab lightness to sit
    /// between the background and the text color, at least `minimumGap` from
    /// the background. Bounding it by the text color keeps a glyph from ever
    /// outshouting the words beside it, whatever the theme.
    static func contrasted(_ color: HexRGB, background: HexRGB, foreground: HexRGB) -> HexRGB {
        let lab = OKLab(color)
        let (backgroundL, foregroundL) = (OKLab(background).l, OKLab(foreground).l)
        let span = abs(foregroundL - backgroundL)
        guard span > 0.05 else { return color }
        let gap = min(minimumGap, span / 2)
        let range = foregroundL > backgroundL
            ? (backgroundL + gap)...foregroundL
            : foregroundL...(backgroundL - gap)
        let l = min(max(lab.l, range.lowerBound), range.upperBound)
        return OKLab(l: l, a: lab.a, b: lab.b).clippedToSRGB()
    }

    static let minimumGap = 0.35

    /// The theme's text hues a state can take — never the bright ones —
    /// with the extended palette's when it is on.
    @MainActor
    static func candidates(in colors: Palette) -> [PaletteHue: HexRGB] {
        var candidates: [PaletteHue: HexRGB] = [:]
        for slot in slots {
            candidates[.slot(slot)] = colors.rgb(forSlot: slot) ?? fallbackSlots[slot]
        }
        if colors.usesExtendedPalette {
            for hue in ExtendedHue.allCases {
                candidates[.extended(hue)] = colors.rgb(forExtended: hue, bright: false)
            }
        }
        return candidates
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

        init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }

        init(l: Double, chroma: Double, hue: Double) {
            self.init(l: l, a: chroma * cos(hue), b: chroma * sin(hue))
        }

        var chroma: Double { (a * a + b * b).squareRoot() }

        /// OKLCH hue in radians, in (-π, π].
        var hue: Double { atan2(b, a) }

        /// The OKLCH midpoint: mean lightness and chroma, and the mean hue
        /// along the shorter arc between the two. A gray's hue is noise, so a
        /// gray beside a color lends only lightness and chroma, and two grays
        /// average in a/b.
        static func midpoint(_ x: OKLab, _ y: OKLab) -> OKLab {
            let l = (x.l + y.l) / 2
            let chroma = (x.chroma + y.chroma) / 2
            switch (x.chroma < LinearStateColor.neutralChroma, y.chroma < LinearStateColor.neutralChroma) {
            case (true, true): return OKLab(l: l, a: (x.a + y.a) / 2, b: (x.b + y.b) / 2)
            case (true, false): return OKLab(l: l, chroma: chroma, hue: y.hue)
            case (false, true): return OKLab(l: l, chroma: chroma, hue: x.hue)
            case (false, false): break
            }
            var delta = y.hue - x.hue
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            return OKLab(l: l, chroma: chroma, hue: x.hue + delta / 2)
        }

        /// Unclamped linear-light sRGB components.
        private var linearRGB: (Double, Double, Double) {
            let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return (
                4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
            )
        }

        private var isInGamut: Bool {
            let (r, g, b) = linearRGB
            return [r, g, b].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
        }

        /// Gives up chroma, never lightness or hue, until the color fits sRGB.
        func clippedToSRGB() -> HexRGB {
            var low = 0.0
            var high = 1.0
            if !isInGamut {
                for _ in 0..<20 {
                    let mid = (low + high) / 2
                    if OKLab(l: l, a: a * mid, b: b * mid).isInGamut { low = mid } else { high = mid }
                }
            }
            let fitted = isInGamut ? self : OKLab(l: l, a: a * low, b: b * low)
            func encode(_ c: Double) -> Double {
                let c = min(max(c, 0), 1)
                return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            let (r, g, b) = fitted.linearRGB
            return HexRGB(red: encode(r), green: encode(g), blue: encode(b))
        }

        /// Lightness counts for half, since a theme tunes its palette's
        /// lightness to its background and the hue is what carries meaning.
        func distance(to other: OKLab) -> Double {
            let dl = (l - other.l) * 0.5
            return (dl * dl + (a - other.a) * (a - other.a) + (b - other.b) * (b - other.b)).squareRoot()
        }
    }
}
