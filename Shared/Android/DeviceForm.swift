import Foundation

/// A best-effort form factor. Only an emulator's `config.ini` can show a hinge, so a physical
/// foldable is recognized by its model name.
nonisolated enum DeviceForm: String, Codable, Sendable, CaseIterable {
    case phone
    case tablet
    case foldable

    static let tabletSmallestWidthDP = 600

    static func classify(smallestWidthDP: Int?, hinge: Bool = false) -> DeviceForm? {
        if hinge { return .foldable }
        guard let smallestWidthDP else { return nil }
        return smallestWidthDP >= tabletSmallestWidthDP ? .tablet : .phone
    }

    /// The `WxH` or integer ending a line of `wm size` or `wm density` output. An `Override` line
    /// wins over the `Physical` line before it.
    static func wmValue(_ output: String) -> String? {
        var value: String?
        for line in output.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: /:\s*(\d+x\d+|\d+)\s*$/) {
                value = String(match.1)
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("Override") { break }
        }
        return value
    }

    static func smallestWidthDP(wmSize: String, wmDensity: String) -> Int? {
        guard let size = wmValue(wmSize), let density = wmValue(wmDensity).flatMap(Int.init), density > 0 else {
            return nil
        }
        let sides = size.split(separator: "x").compactMap { Int($0) }
        guard sides.count == 2 else { return nil }
        return min(sides[0], sides[1]) * 160 / density
    }

    /// Nil when the file names no screen and no hinge.
    static func avdForm(configINI: String) -> DeviceForm? {
        let config = AVDCatalog.parseINI(configINI)
        let hinge = config["hw.sensor.hinge"]?.lowercased() == "yes"
        guard let width = config["hw.lcd.width"].flatMap(Int.init),
              let height = config["hw.lcd.height"].flatMap(Int.init),
              let density = config["hw.lcd.density"].flatMap(Int.init), density > 0
        else { return hinge ? .foldable : nil }
        return classify(smallestWidthDP: min(width, height) * 160 / density, hinge: hinge)
    }

    static func modelLooksFoldable(_ model: String) -> Bool {
        model.range(of: "fold|flip", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `model` is nil for an emulator, whose model name says nothing about a hinge.
    static func liveForm(wmSize: String, wmDensity: String, model: String?) -> DeviceForm? {
        classify(
            smallestWidthDP: smallestWidthDP(wmSize: wmSize, wmDensity: wmDensity),
            hinge: model.map(modelLooksFoldable) ?? false
        )
    }
}
