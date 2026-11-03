import Foundation

/// The Home view's header, chosen by the hour of the day.
enum HomeGreeting: Equatable {
    case morning
    case afternoon
    case evening
    case night

    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<21: self = .evening
        default: self = .night
        }
    }

    init(date: Date, calendar: Calendar = .current) {
        self.init(hour: calendar.component(.hour, from: date))
    }

    var title: String {
        switch self {
        case .morning: "Good morning"
        case .afternoon: "Good afternoon"
        case .evening: "Good evening"
        case .night: "Good night"
        }
    }

    var symbolName: String {
        switch self {
        case .morning: "sun.horizon.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "sun.horizon.fill"
        case .night: "moon.stars.fill"
        }
    }

    /// What the glyph's color is matched to: Lum's bright lemon for the sun,
    /// its bright blueberry for the moon.
    var glyphTarget: HexRGB {
        switch self {
        case .night: ExtendedHue.blueberry.lumBrightRGB
        case .morning, .afternoon, .evening: ExtendedHue.lemon.lumBrightRGB
        }
    }

    /// The theme's bright color nearest `glyphTarget` in hue, skipping grays,
    /// or nil when none is left. Lum without its extended palette takes bright
    /// tangerine and bright blue raspberry instead.
    @MainActor
    func glyphRGB(in colors: Palette) -> HexRGB? {
        if colors.isLum && !colors.usesExtendedPalette {
            return colors.rgb(forSlot: self == .night ? 12 : 11)
        }
        let candidates = LinearStateColor.candidates(in: colors, bright: true)
        return LinearStateColor.nearest(to: glyphTarget, among: candidates) { $0.hueDistance(to: $1) }
            .flatMap { candidates[$0] }
    }
}
