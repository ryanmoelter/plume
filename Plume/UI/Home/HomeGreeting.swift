import Foundation

/// The Home view's header, chosen by the hour of the day.
enum HomeGreeting: Equatable {
    case morning
    case day
    case evening
    case night

    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .day
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
        case .day: "Good day"
        case .evening: "Good evening"
        case .night: "Good night"
        }
    }

    var symbolName: String {
        switch self {
        case .morning: "sun.horizon.fill"
        case .day: "sun.max.fill"
        case .evening: "sun.horizon.fill"
        case .night: "moon.stars.fill"
        }
    }

    /// What the glyph's color is matched to: Lum's bright lemon for the sun,
    /// its bright blueberry for the moon.
    var glyphTarget: HexRGB {
        switch self {
        case .night: HexRGB(hex: "5765d5")!
        case .morning, .day, .evening: HexRGB(hex: "f4cc25")!
        }
    }

    /// The theme's bright color nearest `glyphTarget`, or nil without a palette.
    @MainActor
    func glyphRGB(in colors: Palette) -> HexRGB? {
        var candidates = (9...14).compactMap(colors.rgb(forSlot:))
        if colors.usesExtendedPalette {
            candidates += ExtendedHue.allCases.compactMap { colors.rgb(forExtended: $0, bright: true) }
        }
        let target = LinearStateColor.OKLab(glyphTarget)
        return candidates.min {
            target.distance(to: LinearStateColor.OKLab($0)) < target.distance(to: LinearStateColor.OKLab($1))
        }
    }
}
