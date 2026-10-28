import Foundation
import Observation

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
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !fields[0].hasPrefix("emulator-") else { return nil }
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
}

/// Tracks physical devices adb can see. Polls only while retained, since adb has nothing to watch.
@MainActor @Observable
final class PhysicalDeviceDiscovery {
    static let shared = PhysicalDeviceDiscovery()
    static let pollInterval: Duration = .seconds(2)

    private(set) var devices: [PhysicalDevice] = []
    private(set) var adbURL: URL?

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let list: @Sendable () async -> ADBListing

    init(list: @escaping @Sendable () async -> ADBListing = PhysicalDeviceDiscovery.liveList) {
        self.list = list
    }

    func retain() {
        retainCount += 1
        guard retainCount == 1 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        guard retainCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let listing = await list()
        if listing.adbURL != adbURL { adbURL = listing.adbURL }
        if listing.devices != devices {
            EmulatorLog.info("physical devices: \(listing.devices.map { "\($0.serial) (\($0.state))" })")
            devices = listing.devices
        }
    }

    nonisolated static func liveList() async -> ADBListing {
        guard let adb = await AndroidSDKLocator.locate().sdk?.adbURL else { return ADBListing(adbURL: nil, devices: []) }
        let output = await Task.detached(priority: .userInitiated) {
            AndroidSDKLocator.runCapturingOutput(executable: adb.path, arguments: ["devices", "-l"], timeout: 5)
        }.value
        return ADBListing(adbURL: adb, devices: output.map(ADBDeviceList.parse) ?? [])
    }
}
