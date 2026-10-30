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
        case .day: "sun.max"
        case .evening: "sun.horizon.fill"
        case .night: "moon.stars"
        }
    }
}
