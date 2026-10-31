import Foundation

nonisolated struct PhysicalDevice: Hashable, Sendable, Identifiable {
    enum State: Hashable, Sendable {
        case ready
        case unauthorized
        case offline
        case other(String)
    }

    let serial: String
    let state: State
    let model: String?

    var id: String { serial }
    var isReady: Bool { state == .ready }
    var displayName: String { model?.replacingOccurrences(of: "_", with: " ") ?? serial }
}

nonisolated enum ADBDeviceList {
    /// Parses `adb devices -l`. Emulators are dropped: they reach the picker through their discovery files.
    static func parse(_ output: String) -> [PhysicalDevice] {
        parseIncludingEmulators(output).filter { !$0.serial.hasPrefix("emulator-") }
    }

    static func parseIncludingEmulators(_ output: String) -> [PhysicalDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            return PhysicalDevice(serial: fields[0], state: state(fields[1]), model: model?.isEmpty == false ? model : nil)
        }
    }

    private static func state(_ word: String) -> PhysicalDevice.State {
        switch word {
        case "device": .ready
        case "unauthorized": .unauthorized
        case "offline": .offline
        default: .other(word)
        }
    }
}

nonisolated struct ADBListing: Sendable, Equatable {
    var adbURL: URL?
    var devices: [PhysicalDevice]

    static func live() async -> ADBListing {
        guard let adb = await AndroidSDKLocator.locate().sdk?.adbURL else { return ADBListing(adbURL: nil, devices: []) }
        let output = await Task.detached(priority: .userInitiated) {
            AndroidSDKLocator.runCapturingOutput(executable: adb.path, arguments: ["devices", "-l"], timeout: 5)
        }.value
        return ADBListing(adbURL: adb, devices: output.map(ADBDeviceList.parse) ?? [])
    }
}
