import Testing
import Foundation
import SwiftUI
import GhosttyTheme
@testable import Plume

/// The extended palette gives Lum its own six extra hues exactly, and any
/// other theme each one as the OKLCH midpoint of its ANSI neighbors, inside
/// sRGB. Linear matching takes only its text colors, the Home glyphs the
/// bright colors nearest Lum's lemon and blueberry, and it is on by default only for Lum.
@MainActor
struct ExtendedPaletteTests {
    private typealias OKLab = LinearStateColor.OKLab

    private func hex(_ value: String) -> HexRGB { HexRGB(hex: value)! }

    private func lum() throws -> GhosttyThemeResolver.ResolvedDefinitions {
        try #require(GhosttyRuntime.bundledLumDefinitions)
    }

    private func extendedRGB(
        _ hue: ExtendedHue,
        bright: Bool,
        in definition: GhosttyThemeDefinition?,
        lum: GhosttyThemeResolver.ResolvedDefinitions
    ) -> HexRGB? {
        definition.flatMap { ExtendedPalette.Colors($0, lum: lum).rgb(hue, bright: bright) }
    }

    /// Tomorrow Night, ghostty's own default palette.
    private let tomorrowNight = GhosttyThemeDefinition(
        name: "Tomorrow Night",
        background: "1d1f21",
        foreground: "c5c8c6",
        palette: [
            0: "1d1f21", 1: "cc6666", 2: "b5bd68", 3: "f0c674", 4: "81a2be", 5: "b294bb", 6: "8abeb7", 7: "c5c8c6",
            8: "666666", 9: "d54e53", 10: "b9ca4a", 11: "e7c547", 12: "7aa6da", 13: "c397d8", 14: "70c0b1", 15: "eaeaea",
        ]
    )

    // Lum's own table: text dark, text light, bright.
    @Test(arguments: [
        (ExtendedHue.peach, "ff9279", "bc4c33", "de583a"),
        (.lemon, "ebc843", "987e00", "f4cc25"),
        (.turteal, "71e79d", "36955d", "57db8c"),
        (.amf, "00d1f1", "008ba1", "23b9d4"),
        (.blueberry, "95a7ff", "5664c1", "5765d5"),
        (.eggplant, "e384d2", "9d448f", "a43594"),
    ])
    func lumGetsItsOwnColors(hue: ExtendedHue, dark: String, light: String, bright: String) throws {
        let lum = try lum()
        #expect(extendedRGB(hue, bright: false, in: lum.dark, lum: lum) == hex(dark))
        #expect(extendedRGB(hue, bright: false, in: lum.light, lum: lum) == hex(light))
        #expect(extendedRGB(hue, bright: true, in: lum.dark, lum: lum) == hex(bright))
        #expect(extendedRGB(hue, bright: true, in: lum.light, lum: lum) == hex(bright))
    }

    @Test func lumIsRecognizedByItsPaletteNotItsName() throws {
        let lum = try lum()
        let dark = try #require(lum.dark)
        let renamed = GhosttyThemeDefinition(
            name: "My theme",
            background: "000000",
            foreground: "ffffff",
            palette: dark.palette.mapValues { "#" + $0.uppercased().replacingOccurrences(of: "#", with: "") }
        )
        #expect(extendedRGB(.peach, bright: false, in: renamed, lum: lum) == hex("ff9279"))

        var tweaked = dark.palette
        tweaked[13] = "8046bb"
        let nearlyLum = GhosttyThemeDefinition(name: "Lum dark", background: "211a14", foreground: "f6ece4", palette: tweaked)
        #expect(extendedRGB(.peach, bright: false, in: nearlyLum, lum: lum) != hex("ff9279"))
    }

    /// Whether `m` lies on the shorter arc from `x` to `y`.
    private func hue(_ m: Double, liesBetween x: Double, and y: Double) -> Bool {
        func arc(_ p: Double, _ q: Double) -> Double {
            let d = abs(p - q).truncatingRemainder(dividingBy: 2 * .pi)
            return min(d, 2 * .pi - d)
        }
        return abs(arc(x, m) + arc(m, y) - arc(x, y)) < 0.05
    }

    @Test(arguments: ExtendedHue.allCases, [false, true])
    func anotherThemeInterpolatesBetweenTheNeighbors(hue: ExtendedHue, bright: Bool) throws {
        let lum = try lum()
        let offset = bright ? 8 : 0
        let (first, second) = hue.neighborSlots
        let x = OKLab(hex(try #require(tomorrowNight.palette[first + offset])))
        let y = OKLab(hex(try #require(tomorrowNight.palette[second + offset])))
        let m = OKLab(try #require(extendedRGB(hue, bright: bright, in: tomorrowNight, lum: lum)))

        #expect(self.hue(m.hue, liesBetween: x.hue, and: y.hue))
        #expect(m.l >= min(x.l, y.l) - 0.01 && m.l <= max(x.l, y.l) + 0.01)
        #expect(m.chroma >= min(x.chroma, y.chroma) - 0.01 && m.chroma <= max(x.chroma, y.chroma) + 0.01)
    }

    @Test func eggplantsHueWrapsThroughRed() throws {
        let lum = try lum()
        // Magenta at 300° and red at 20°: the mean is 340°, where a naive
        // average of the angles lands on 160°, a green.
        func color(hue degrees: Double) -> String {
            let rgb = OKLab(l: 0.65, chroma: 0.1, hue: degrees * .pi / 180).clippedToSRGB()
            return String(format: "%02x%02x%02x", Int((rgb.red * 255).rounded()), Int((rgb.green * 255).rounded()), Int((rgb.blue * 255).rounded()))
        }
        let theme = GhosttyThemeDefinition(name: "Wheel", background: "000000", foreground: "ffffff", palette: [1: color(hue: 20), 5: color(hue: 300)])
        let eggplant = OKLab(try #require(extendedRGB(.eggplant, bright: false, in: theme, lum: lum)))
        let degrees = (eggplant.hue * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        #expect(abs(degrees - 340) < 3)
    }

    @Test func aGrayNeighborLendsNoHue() throws {
        let lum = try lum()
        let theme = GhosttyThemeDefinition(
            name: "Gray cyan",
            background: "000000",
            foreground: "ffffff",
            palette: [2: "b5bd68", 4: "81a2be", 6: "808080"]
        )
        let green = OKLab(hex("b5bd68"))
        let blue = OKLab(hex("81a2be"))
        let turteal = OKLab(try #require(extendedRGB(.turteal, bright: false, in: theme, lum: lum)))
        let amf = OKLab(try #require(extendedRGB(.amf, bright: false, in: theme, lum: lum)))
        #expect(hue(turteal.hue, liesBetween: green.hue, and: green.hue))
        #expect(hue(amf.hue, liesBetween: blue.hue, and: blue.hue))

        let grays = OKLab.midpoint(OKLab(hex("808080")), OKLab(hex("7f8082")))
        #expect(grays.chroma < LinearStateColor.neutralChroma)
    }

    @Test func theMidpointTakesTheShorterArcAcrossPi() {
        let x = OKLab(l: 0.6, chroma: 0.1, hue: 170 * .pi / 180)
        let y = OKLab(l: 0.6, chroma: 0.1, hue: -170 * .pi / 180)
        #expect(abs(abs(OKLab.midpoint(x, y).hue) - .pi) < 0.001)
    }

    @Test func aMidpointOutsideSRGBGivesUpChromaNotHue() throws {
        let lum = try lum()
        let theme = GhosttyThemeDefinition(
            name: "Saturated",
            background: "000000",
            foreground: "ffffff",
            palette: [1: "ff0000", 2: "00ff00", 3: "ffff00", 4: "0000ff", 5: "ff00ff", 6: "00ffff"]
        )
        for hue in ExtendedHue.allCases {
            let (first, second) = hue.neighborSlots
            let ideal = OKLab.midpoint(OKLab(hex(theme.palette[first]!)), OKLab(hex(theme.palette[second]!)))
            let rgb = try #require(extendedRGB(hue, bright: false, in: theme, lum: lum))
            #expect([rgb.red, rgb.green, rgb.blue].allSatisfy { (0...1).contains($0) })
            let fitted = OKLab(rgb)
            #expect(fitted.chroma <= ideal.chroma + 0.01)
            #expect(self.hue(fitted.hue, liesBetween: ideal.hue, and: ideal.hue))
        }
    }

    @Test func aMissingNeighborGivesNoColor() throws {
        let lum = try lum()
        let theme = GhosttyThemeDefinition(name: "Sparse", background: "000000", foreground: "ffffff", palette: [1: "cc6666"])
        #expect(extendedRGB(.peach, bright: false, in: theme, lum: lum) == nil)
        #expect(extendedRGB(.peach, bright: false, in: nil, lum: lum) == nil)
    }

    // MARK: - Linear

    private func palette(
        _ definitions: GhosttyThemeResolver.ResolvedDefinitions?,
        _ colorScheme: ColorScheme = .dark,
        extended: Bool
    ) -> Palette {
        Palette(colorScheme: colorScheme, definitions: definitions, usesExtendedPalette: extended)
    }

    @Test func linearMatchingConsidersOnlyTextColors() throws {
        let lum = try lum()
        let colors = palette(lum, extended: true)
        let candidates = LinearStateColor.candidates(in: colors, bright: false)
        #expect(candidates.count == 12)
        #expect(candidates[.extended(.lemon)] == hex("ebc843"))
        #expect(candidates[.slot(3)] == hex("ffaf5e"))

        let brights = Set(((9...14).compactMap(colors.rgb(forSlot:)) + ExtendedHue.allCases.compactMap { colors.rgb(forExtended: $0, bright: true) }).map { "\($0)" })
        let mapped = try #require(LinearIssueGlyph.rgb(for: "f4cc25", strategy: .themePalette, in: colors))
        #expect(mapped == hex("ebc843"))
        #expect(!brights.contains("\(mapped)"))
    }

    @Test func linearMatchingSkipsExtendedHuesWhenOff() throws {
        let colors = palette(try lum(), extended: false)
        #expect(Set(LinearStateColor.candidates(in: colors, bright: false).keys) == Set(LinearStateColor.slots.map(PaletteHue.slot)))
    }

    // MARK: - Home

    @Test func homeGlyphsTakeLumsLemonAndBlueberry() throws {
        let lum = try lum()
        for scheme in [ColorScheme.dark, .light] {
            let colors = palette(lum, scheme, extended: true)
            #expect(HomeGreeting.day.glyphRGB(in: colors) == hex("f4cc25"))
            #expect(HomeGreeting.morning.glyphRGB(in: colors) == hex("f4cc25"))
            #expect(HomeGreeting.night.glyphRGB(in: colors) == hex("5765d5"))
        }
    }

    @Test func homeGlyphsTakeTheNearestBrightSlotsWithoutTheExtendedPalette() throws {
        let colors = palette(try lum(), extended: false)
        // Lum's nearest bright slots: lime for the lemon, grape for the blueberry.
        #expect(HomeGreeting.day.glyphRGB(in: colors) == hex("aed83f"))
        #expect(HomeGreeting.night.glyphRGB(in: colors) == hex("8046ba"))
    }

    @Test func homeGlyphsOnAnotherTheme() throws {
        let definitions = GhosttyThemeResolver.ResolvedDefinitions(light: nil, dark: tomorrowNight)
        let off = palette(definitions, extended: false)
        #expect(HomeGreeting.day.glyphRGB(in: off) == hex("e7c547"))
        #expect(HomeGreeting.night.glyphRGB(in: off) == hex("7aa6da"))

        let on = palette(definitions, extended: true)
        let candidates = (9...14).compactMap(on.rgb(forSlot:))
            + ExtendedHue.allCases.compactMap { on.rgb(forExtended: $0, bright: true) }
        for greeting in [HomeGreeting.day, .night] {
            let target = OKLab(greeting.glyphTarget)
            let chosen = try #require(greeting.glyphRGB(in: on))
            #expect(candidates.contains(chosen))
            let offChoice = try #require(greeting.glyphRGB(in: off))
            #expect(target.distance(to: OKLab(chosen)) <= target.distance(to: OKLab(offChoice)))
        }
    }

    @Test func homeGlyphsSkipAGrayYellowSlot() throws {
        var grayYellow = tomorrowNight.palette
        grayYellow[11] = "808080"
        let theme = GhosttyThemeDefinition(name: "Gray yellow", background: "1d1f21", foreground: "c5c8c6", palette: grayYellow)
        let colors = palette(.init(light: nil, dark: theme), extended: false)
        let sun = try #require(HomeGreeting.day.glyphRGB(in: colors))
        #expect(sun != hex("808080"))
        #expect(OKLab(sun).chroma >= LinearStateColor.neutralChroma)

        let allGray = GhosttyThemeDefinition(
            name: "Grays",
            background: "000000",
            foreground: "ffffff",
            palette: Dictionary(uniqueKeysWithValues: (0...15).map { ($0, "808080") })
        )
        #expect(HomeGreeting.day.glyphRGB(in: palette(.init(light: nil, dark: allGray), extended: true)) == nil)
    }

    @Test func homeGlyphsHaveNoColorWithoutAPalette() {
        #expect(HomeGreeting.day.glyphRGB(in: palette(nil, extended: true)) == nil)
    }

    // MARK: - Default and accent

    @Test func theExtendedPaletteDefaultsOnOnlyForLum() throws {
        let lum = try lum()
        func defaultsOn(_ definitions: GhosttyThemeResolver.ResolvedDefinitions?) -> Bool {
            ExtendedPalette.Resolved(definitions, lum: lum).defaultsOn
        }
        #expect(defaultsOn(lum))
        #expect(defaultsOn(.init(light: lum.dark, dark: lum.dark)))
        #expect(!defaultsOn(.init(light: nil, dark: tomorrowNight)))
        #expect(!defaultsOn(.init(light: lum.light, dark: tomorrowNight)))
        #expect(!defaultsOn(nil))
    }

    @Test func theToggleFollowsTheRuntimesThemeUntilTheUserChooses() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "ExtendedPaletteTests-\(UUID().uuidString)")!)
        let runtime = GhosttyRuntime()
        #expect(!ThemeChrome.usesExtendedPalette(settings: settings, runtime: runtime))

        runtime.adopt(try lum())
        #expect(ThemeChrome.usesExtendedPalette(settings: settings, runtime: runtime))
        runtime.adopt(.init(light: nil, dark: tomorrowNight))
        #expect(!ThemeChrome.usesExtendedPalette(settings: settings, runtime: runtime))

        settings.extendedPaletteChoice = true
        #expect(ThemeChrome.usesExtendedPalette(settings: settings, runtime: runtime))
        runtime.adopt(try lum())
        settings.extendedPaletteChoice = false
        #expect(!ThemeChrome.usesExtendedPalette(settings: settings, runtime: runtime))
    }

    @Test func theRuntimeRefreshesItsExtendedColorsWithTheTheme() throws {
        let runtime = GhosttyRuntime()
        runtime.adopt(try lum())
        #expect(runtime.extendedPalette?.dark?.rgb(.peach, bright: false) == hex("ff9279"))
        runtime.adopt(.init(light: nil, dark: tomorrowNight))
        #expect(runtime.extendedPalette?.dark?.rgb(.peach, bright: false) != hex("ff9279"))
        #expect(runtime.extendedPalette?.dark?.isLum == false)
    }

    @Test func anExtendedTintResolvesWhetherOrNotTheToggleIsOn() throws {
        let lum = try lum()
        #expect(palette(lum, extended: false).color(for: .extended(.peach, bright: false)) == Color(hex: "ff9279"))
        #expect(ThemeChrome.accent(.extended(.amf, bright: true), for: .light, in: lum) == Color(hex: "23b9d4"))
        #expect(ThemeChrome.accent(.extended(.amf, bright: true), for: .light, in: nil) == .accentColor)
    }
}
