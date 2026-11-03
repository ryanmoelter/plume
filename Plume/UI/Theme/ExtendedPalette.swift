import GhosttyTheme

/// The six hues Lum adds between the ANSI ones, which make a 12-hue wheel.
nonisolated enum ExtendedHue: String, CaseIterable, Sendable {
    case peach
    case lemon
    case turteal
    case amf
    case blueberry
    case eggplant

    var name: String {
        switch self {
        case .peach: "Peach"
        case .lemon: "Lemon"
        case .turteal: "Turteal"
        case .amf: "AMF"
        case .blueberry: "Blueberry"
        case .eggplant: "Eggplant"
        }
    }

    /// The normal ANSI slots either side of this hue on the wheel.
    var neighborSlots: (Int, Int) {
        switch self {
        case .peach: (1, 3)
        case .lemon: (3, 2)
        case .turteal: (2, 6)
        case .amf: (6, 4)
        case .blueberry: (4, 5)
        case .eggplant: (5, 1)
        }
    }

    fileprivate var lumTextDark: String {
        switch self {
        case .peach: "ff9279"
        case .lemon: "ebc843"
        case .turteal: "71e79d"
        case .amf: "00d1f1"
        case .blueberry: "95a7ff"
        case .eggplant: "e384d2"
        }
    }

    fileprivate var lumTextLight: String {
        switch self {
        case .peach: "bc4c33"
        case .lemon: "987e00"
        case .turteal: "36955d"
        case .amf: "008ba1"
        case .blueberry: "5664c1"
        case .eggplant: "9d448f"
        }
    }

    var lumBrightRGB: HexRGB { HexRGB(hex: lumBright)! }

    fileprivate var lumBright: String {
        switch self {
        case .peach: "de583a"
        case .lemon: "f4cc25"
        case .turteal: "57db8c"
        case .amf: "23b9d4"
        case .blueberry: "5765d5"
        case .eggplant: "a43594"
        }
    }
}

/// One of the 12 hues of the extended palette: an ANSI slot or a hue between two.
nonisolated enum PaletteHue: Hashable, Sendable {
    case slot(Int)
    case extended(ExtendedHue)

    /// Red round to eggplant, the order the pickers show them in.
    static let wheel: [PaletteHue] = [
        .slot(1), .extended(.peach), .slot(3), .extended(.lemon),
        .slot(2), .extended(.turteal), .slot(6), .extended(.amf),
        .slot(4), .extended(.blueberry), .slot(5), .extended(.eggplant),
    ]

    /// The ANSI slots that carry no hue, as a dark-to-light pair of pairs.
    static let neutralSlots = [0, 8, 7, 15]
}

/// The extended palette's colors for one terminal theme.
///
/// A theme whose hues are Lum's gets Lum's own extra colors; any other theme
/// gets each one as the OKLCH midpoint of its two ANSI neighbors, which keeps
/// the theme's own lightness and saturation.
nonisolated enum ExtendedPalette {
    /// Slots 1–6 and their bright variants: what makes a palette Lum's.
    private static let lumSlots = Array(1...6) + Array(9...14)

    private enum LumVariant { case dark, light }

    /// Matches either Lum variant whatever the appearance, since a user may
    /// pin one Lum theme for both.
    private static func lumVariant(
        of definition: GhosttyThemeDefinition,
        lum: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> LumVariant? {
        func matches(_ reference: GhosttyThemeDefinition?) -> Bool {
            guard let reference else { return false }
            return lumSlots.allSatisfy { slot in
                guard let ours = definition.palette[slot].flatMap(HexRGB.init(hex:)) else { return false }
                return ours == reference.palette[slot].flatMap(HexRGB.init(hex:))
            }
        }
        if matches(lum?.dark) { return .dark }
        if matches(lum?.light) { return .light }
        return nil
    }

    /// One theme's extended colors, resolved once so a render never repeats
    /// the Lum check or the interpolation.
    struct Colors: Sendable {
        let isLum: Bool
        private let text: [ExtendedHue: HexRGB]
        private let bright: [ExtendedHue: HexRGB]

        init(_ definition: GhosttyThemeDefinition, lum: GhosttyThemeResolver.ResolvedDefinitions?) {
            let variant = lumVariant(of: definition, lum: lum)
            isLum = variant != nil
            func resolve(bright: Bool) -> [ExtendedHue: HexRGB] {
                var colors: [ExtendedHue: HexRGB] = [:]
                for hue in ExtendedHue.allCases {
                    colors[hue] = ExtendedPalette.rgb(hue, bright: bright, in: definition, variant: variant)
                }
                return colors
            }
            text = resolve(bright: false)
            bright = resolve(bright: true)
        }

        /// Nil when the theme lacks either neighbor.
        func rgb(_ hue: ExtendedHue, bright isBright: Bool) -> HexRGB? {
            isBright ? bright[hue] : text[hue]
        }
    }

    /// Both appearances' extended colors, and whether the palette is on by default.
    struct Resolved: Sendable {
        let light: Colors?
        let dark: Colors?
        /// On when every appearance the theme defines uses Lum's palette.
        let defaultsOn: Bool

        init(_ definitions: GhosttyThemeResolver.ResolvedDefinitions?, lum: GhosttyThemeResolver.ResolvedDefinitions?) {
            light = definitions?.light.map { Colors($0, lum: lum) }
            dark = definitions?.dark.map { Colors($0, lum: lum) }
            let present = [light, dark].compactMap { $0 }
            defaultsOn = !present.isEmpty && present.allSatisfy(\.isLum)
        }
    }

    private static func rgb(
        _ hue: ExtendedHue,
        bright: Bool,
        in definition: GhosttyThemeDefinition,
        variant: LumVariant?
    ) -> HexRGB? {
        switch variant {
        case .dark: return HexRGB(hex: bright ? hue.lumBright : hue.lumTextDark)
        case .light: return HexRGB(hex: bright ? hue.lumBright : hue.lumTextLight)
        case nil: break
        }
        let offset = bright ? 8 : 0
        let (first, second) = hue.neighborSlots
        guard
            let x = definition.palette[first + offset].flatMap(HexRGB.init(hex:)),
            let y = definition.palette[second + offset].flatMap(HexRGB.init(hex:))
        else { return nil }
        return midpoint(x, y)
    }

    static func midpoint(_ x: HexRGB, _ y: HexRGB) -> HexRGB {
        typealias OKLab = LinearStateColor.OKLab
        return OKLab.midpoint(OKLab(x), OKLab(y)).clippedToSRGB()
    }
}
