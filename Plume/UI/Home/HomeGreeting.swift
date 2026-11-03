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

    /// The glyph's color: bright yellow for the sun and bright blue for the
    /// moon, or Lum's lemon and blueberry with the extended palette. Nil
    /// without a palette.
    @MainActor
    func glyphRGB(in colors: Palette) -> HexRGB? {
        let isMoon = self == .night
        if colors.usesExtendedPalette {
            return colors.rgb(forExtended: isMoon ? .blueberry : .lemon, bright: true)
        }
        return colors.rgb(forSlot: isMoon ? 12 : 11)
    }
}
