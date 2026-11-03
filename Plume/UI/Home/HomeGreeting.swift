import Foundation

/// The Home view's header, chosen by the hour of the day.
enum HomeGreeting: String, CaseIterable {
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

    #if DEBUG
    /// The Debug settings' forced greeting, as a raw value; empty is automatic.
    static let debugOverrideKey = "PlumeDebugGreetingOverride"
    #endif

    var name: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    /// The hours `init(hour:)` maps here, as "5 AM–12 PM".
    var hoursText: String {
        let hours = 0..<24
        let start = hours.first { Self(hour: $0) == self && Self(hour: ($0 + 23) % 24) != self } ?? 0
        let end = (1...24).lazy.map { (start + $0) % 24 }.first { Self(hour: $0) != self } ?? start
        return "\(Self.clockHour(start))–\(Self.clockHour(end))"
    }

    private static func clockHour(_ hour: Int) -> String {
        "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
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
