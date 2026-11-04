import Foundation
import Observation

/// Tracks physical devices adb can see. Polls only while retained, since adb has nothing to watch.
@MainActor @Observable
final class PhysicalDeviceDiscovery {
    static let shared = PhysicalDeviceDiscovery()
    static let pollInterval: Duration = .seconds(2)

    private(set) var devices: [PhysicalDevice] = []
    private(set) var adbURL: URL?
    /// Each listed Wi-Fi device's `ro.serialno`, by adb serial, read once per connection.
    @ObservationIgnored private(set) var hardwareSerials: [String: String] = [:]

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored let list: @Sendable () async -> ADBListing
    @ObservationIgnored private let serialNumber: @Sendable (_ adb: URL, _ serial: String) async -> String?

    init(
        list: @escaping @Sendable () async -> ADBListing = ADBListing.live,
        serialNumber: @escaping @Sendable (_ adb: URL, _ serial: String) async -> String? = ADBWireless.serialNumber
    ) {
        self.list = list
        self.serialNumber = serialNumber
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
        await resolveHardwareSerials(in: listing)
        if listing.adbURL != adbURL { adbURL = listing.adbURL }
        if listing.devices != devices {
            EmulatorLog.info("physical devices: \(listing.devices.map { "\($0.serial) (\($0.state))" })")
            devices = listing.devices
        }
    }

    /// What a tab persists for `device`: `wifi:<ro.serialno>` for a Wi-Fi device once its serial
    /// number is known, else the adb serial.
    func identifier(for device: PhysicalDevice) -> String {
        identifier(forSerial: device.serial)
    }

    func identifier(forSerial serial: String) -> String {
        guard ADBWireless.isNetworkSerial(serial), let hardware = hardwareSerials[serial] else { return serial }
        return PhysicalDeviceIdentity.wifi(hardwareSerial: hardware)
    }

    /// The ready adb serial a tab's identifier names now. An exact serial wins; otherwise a phone
    /// with that serial number on either transport does, Wi-Fi first for a `wifi:` identifier.
    func readySerial(for identifier: String) -> String? {
        let ready = devices.filter(\.isReady)
        if let exact = ready.first(where: { $0.serial == identifier }) { return exact.serial }
        let hardware = PhysicalDeviceIdentity.hardwareSerial(of: identifier)
        let overWifi = ready.first { $0.isNetwork && hardwareSerials[$0.serial] == hardware }
        let overUSB = ready.first { !$0.isNetwork && $0.serial == hardware }
        return (PhysicalDeviceIdentity.isWifi(identifier) ? overWifi ?? overUSB : overUSB ?? overWifi)?.serial
    }

    private func resolveHardwareSerials(in listing: ADBListing) async {
        let listed = Set(listing.devices.map(\.serial))
        hardwareSerials = hardwareSerials.filter { listed.contains($0.key) }
        guard let adb = listing.adbURL else { return }
        let unresolved = listing.devices.filter { $0.isNetwork && $0.isReady && hardwareSerials[$0.serial] == nil }.map(\.serial)
        guard !unresolved.isEmpty else { return }
        let resolved = await withTaskGroup(of: (String, String?).self) { [serialNumber] group in
            for serial in unresolved {
                group.addTask { (serial, await serialNumber(adb, serial)) }
            }
            var found: [String: String] = [:]
            for await (serial, hardware) in group { found[serial] = hardware }
            return found
        }
        hardwareSerials.merge(resolved) { $1 }
    }
}
