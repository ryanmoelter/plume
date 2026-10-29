import Foundation

/// One model `android device remote models` offers, at one API level.
nonisolated struct RemoteDeviceModel: Hashable, Sendable, Identifiable {
    let manufacturer: String
    let name: String
    let codename: String
    let api: Int

    /// `codename/api`, the form `create` takes.
    var id: String { "\(codename)/\(api)" }
    var displayName: String { "\(name) (API \(api))" }

    enum FormFactor: Int, CaseIterable, Sendable {
        case tablet, foldable, phone, watch

        var title: String {
            switch self {
            case .tablet: "Tablet"
            case .foldable: "Foldable"
            case .phone: "Phone"
            case .watch: "Watch"
            }
        }

        var groupTitle: String { title + "s" }

        var symbol: String {
            switch self {
            case .tablet: "ipad.landscape"
            case .foldable, .phone: "iphone"
            case .watch: "applewatch"
            }
        }
    }

    var formFactor: FormFactor { FormFactor(modelName: name) }
}

extension RemoteDeviceModel.FormFactor {
    /// Guessed from the model name, since the service reports no form factor.
    init(modelName name: String) {
        if name.range(of: #"\b(Tab|Tablet|Pad)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            self = .tablet
            return
        }
        let foldableMarkers = ["Fold", "Flip", "razr", "Magic V"]
        if foldableMarkers.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            self = .foldable
        } else if name.localizedCaseInsensitiveContains("Watch") {
            self = .watch
        } else {
            self = .phone
        }
    }
}

nonisolated struct RemoteReservationRow: Hashable, Sendable {
    let id: String
    /// `ACTIVE`, `FINISHED`, or whatever else the service reports.
    let state: String
    let expiresAt: Date?
    let manufacturer: String?
    let model: String?
    let codename: String?
    let api: Int?

    enum Phase: Equatable, Sendable { case active, ended, unknown }

    /// Only a state known to end a reservation reads as ended; anything new keeps the tab.
    var phase: Phase {
        switch state {
        case "ACTIVE": .active
        case "FINISHED", "CANCELLED", "EXPIRED", "ENDED": .ended
        default: .unknown
        }
    }
}

nonisolated enum RemoteConnectOutcome: Equatable, Sendable {
    case connected(port: Int)
    /// A connection entry from an earlier `connect` is still recorded.
    case alreadyConnected(port: Int)
    case failed
}

/// Parsers for the `android` tool's plain-text output. None of its commands print JSON.
nonisolated enum RemoteDeviceParsers {
    static func signedInAccount(_ output: String) -> String? {
        lines(output).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("Logged in as ") }
            .map { String($0.dropFirst("Logged in as ".count)) }
    }

    /// The tool redraws a spinner with carriage returns before printing the list.
    static func projects(_ output: String) -> [String] {
        let all = lines(output)
        guard let header = all.firstIndex(where: { $0.contains("Projects ready for streaming") }) else { return [] }
        return all[(header + 1)...]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") && !$0.contains(" ") }
    }

    /// Reads the manufacturer tree. A row lists one `codename/api` column per API level it offers.
    static func models(_ output: String) -> [RemoteDeviceModel] {
        var manufacturer: String?
        var models: [RemoteDeviceModel] = []
        for line in lines(output) {
            if let rest = branch(line, atRoot: true) {
                manufacturer = rest.replacingOccurrences(of: #"\s*\[\d+\]$"#, with: "", options: .regularExpression)
            } else if let rest = branch(line, atRoot: false), let manufacturer {
                let columns = columns(rest)
                guard let name = columns.first else { continue }
                for column in columns.dropFirst() {
                    guard let slash = column.lastIndex(of: "/"), let api = Int(column[column.index(after: slash)...]) else { continue }
                    models.append(RemoteDeviceModel(manufacturer: manufacturer, name: name, codename: String(column[..<slash]), api: api))
                }
            }
        }
        return models
    }

    static func reservations(_ output: String, now: Date = Date(), calendar: Calendar = .current) -> [RemoteReservationRow] {
        lines(output).compactMap { line in
            let columns = columns(line)
            guard columns.count >= 3, columns[0] != "Reservation", !line.hasPrefix(" "),
                  columns[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  columns[1].allSatisfy({ $0.isUppercase || $0 == "_" })
            else { return nil }
            func column(_ index: Int) -> String? { index < columns.count ? columns[index] : nil }
            return RemoteReservationRow(
                id: columns[0],
                state: columns[1],
                expiresAt: clockTime(columns[2], now: now, calendar: calendar),
                manufacturer: column(3),
                model: column(4),
                codename: column(5),
                api: column(6).flatMap(Int.init)
            )
        }
    }

    /// Whether `list` printed its table, even an empty one, or said nothing is reserved. Only
    /// then does a missing row mean the reservation ended.
    static func isReservationListing(_ output: String) -> Bool {
        output.contains("There are no active reservations")
            || lines(output).contains { columns($0).starts(with: ["Reservation", "State"]) }
    }

    /// `New reservation created with id 3f3jpxdv5lw6y. Reservation ends at 10:51 PM`
    static func createdReservation(_ output: String, now: Date = Date(), calendar: Calendar = .current) -> (id: String, endsAt: Date?)? {
        for line in lines(output) {
            guard let match = line.firstMatch(of: /created with id ([A-Za-z0-9_-]+)/) else { continue }
            let endsAt = line.firstMatch(of: /ends at (.+)$/).flatMap { clockTime(String($0.1), now: now, calendar: calendar) }
            return (String(match.1), endsAt)
        }
        return nil
    }

    static func connectOutcome(_ result: AndroidCLIResult) -> RemoteConnectOutcome {
        let output = result.output
        if let match = output.firstMatch(of: /already connected on port (\d+)/), let port = Int(match.1) {
            return .alreadyConnected(port: port)
        }
        if result.succeeded, let match = output.firstMatch(of: /connected on port (\d+)/), let port = Int(match.1) {
            return .connected(port: port)
        }
        return .failed
    }

    /// `Reservation extended. New expire time: 10:57 PM`
    static func extendedExpiry(_ output: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        output.firstMatch(of: /New expire time: ([^\n]+)/).flatMap { clockTime(String($0.1), now: now, calendar: calendar) }
    }

    /// `remove` of a reservation that already ended.
    static func saysAlreadyEnded(_ output: String) -> Bool {
        output.contains("has already ended")
    }

    /// `disconnect` of a reservation with no connection.
    static func saysNotConnected(_ output: String) -> Bool {
        output.contains("No active connection found")
    }

    /// The tool prints a clock time with no date. Takes the date that puts it nearest `now`, so an
    /// expiry just past midnight lands tomorrow and one just before it lands yesterday.
    static func clockTime(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let normalized = normalizeSpaces(text).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["h:mm a", "h:mm:ss a", "H:mm", "H:mm:ss"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: normalized) else { continue }
            let parts = calendar.dateComponents([.hour, .minute, .second], from: parsed)
            guard let today = calendar.date(
                bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0, of: now
            ) else { return nil }
            let halfDay: TimeInterval = 12 * 60 * 60
            let offset = today.timeIntervalSince(now)
            if offset < -halfDay { return calendar.date(byAdding: .day, value: 1, to: today) }
            if offset > halfDay { return calendar.date(byAdding: .day, value: -1, to: today) }
            return today
        }
        return nil
    }

    // MARK: Private

    private static func lines(_ output: String) -> [String] {
        output.replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
    }

    /// The tool writes times with a narrow no-break space, which would read as a column gap.
    private static func normalizeSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Columns are separated by two or more spaces; a value such as a model name may hold one.
    private static func columns(_ line: String) -> [String] {
        normalizeSpaces(line)
            .components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The text after a `├─`/`└─` marker: at the start of the line for a manufacturer, or after
    /// the `│` gutter for a model.
    private static func branch(_ line: String, atRoot: Bool) -> String? {
        let markers = ["├─", "└─"]
        var rest = Substring(line)
        if !atRoot {
            let gutter = rest.prefix { $0 == "│" || $0 == " " }
            guard !gutter.isEmpty else { return nil }
            rest = rest.dropFirst(gutter.count)
        }
        guard let marker = markers.first(where: { rest.hasPrefix($0) }) else { return nil }
        let text = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
