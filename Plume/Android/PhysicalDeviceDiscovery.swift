import Foundation
import Observation

/// Tracks physical devices adb can see. Polls only while retained, since adb has nothing to watch.
@MainActor @Observable
final class PhysicalDeviceDiscovery {
    static let shared = PhysicalDeviceDiscovery()
    static let pollInterval: Duration = .seconds(2)

    private(set) var devices: [PhysicalDevice] = []
    private(set) var adbURL: URL?

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored let list: @Sendable () async -> ADBListing

    init(list: @escaping @Sendable () async -> ADBListing = ADBListing.live) {
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
}
