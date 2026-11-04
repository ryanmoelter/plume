import Foundation
import Observation

/// Tracks physical devices adb can see. Polls only while retained, since adb has nothing to watch.
@MainActor @Observable
final class PhysicalDeviceDiscovery {
    static let shared = PhysicalDeviceDiscovery()
    static let pollInterval: Duration = .seconds(2)

    private(set) var devices: [PhysicalDevice] = []
    private(set) var adbURL: URL?
    /// Each listed Wi-Fi device's `ro.serialno`, by adb serial.
    @ObservationIgnored private(set) var hardwareSerials: [String: String] = [:]

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored let list: @Sendable () async -> ADBListing
    @ObservationIgnored private let serialNumber: @Sendable (_ adb: URL, _ serial: String) async -> String?
    /// One read per adb serial for as long as adb lists it, kept when it fails so a phone that
    /// won't answer isn't asked again on every poll.
    @ObservationIgnored private var serialLookups: [String: Task<String?, Never>] = [:]
    @ObservationIgnored private var startedRefreshes = 0
    @ObservationIgnored private var publishedRefresh = 0

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

    /// Publishes the listing at once, then waits for the serial numbers of its Wi-Fi devices. A
    /// listing older than one already published is dropped, so overlapping refreshes never go back.
    func refresh() async {
        startedRefreshes += 1
        let refresh = startedRefreshes
        let listing = await list()
        guard refresh > publishedRefresh else { return }
        publishedRefresh = refresh
        publish(listing)
        guard let adb = listing.adbURL else { return }
        let lookups = listing.devices.filter { $0.isNetwork && $0.isReady }.map { lookup(of: $0.serial, adb: adb) }
        for (serial, lookup) in lookups { await finish(lookup, of: serial) }
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

    /// Reads the serial number now when it isn't known, for a caller that can't wait for a poll.
    func resolvedIdentifier(forSerial serial: String) async -> String {
        guard ADBWireless.isNetworkSerial(serial) else { return serial }
        if hardwareSerials[serial] == nil, let adb = await currentADB() {
            let (serial, lookup) = lookup(of: serial, adb: adb)
            await finish(lookup, of: serial)
        }
        return identifier(forSerial: serial)
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

    private func publish(_ listing: ADBListing) {
        if listing.adbURL != adbURL { adbURL = listing.adbURL }
        if listing.devices != devices {
            EmulatorLog.info("physical devices: \(listing.devices.map { "\($0.serial) (\($0.state))" })")
            devices = listing.devices
        }
        let listed = Set(listing.devices.map(\.serial))
        hardwareSerials = hardwareSerials.filter { listed.contains($0.key) }
        serialLookups = serialLookups.filter { listed.contains($0.key) }
    }

    private func lookup(of serial: String, adb: URL) -> (String, Task<String?, Never>) {
        if let existing = serialLookups[serial] { return (serial, existing) }
        let lookup = Task { [serialNumber] in await serialNumber(adb, serial) }
        serialLookups[serial] = lookup
        return (serial, lookup)
    }

    private func finish(_ lookup: Task<String?, Never>, of serial: String) async {
        let hardware = await lookup.value
        // A lookup dropped while it ran belongs to a connection adb no longer lists.
        guard serialLookups[serial] == lookup, let hardware else { return }
        hardwareSerials[serial] = hardware
    }

    private func currentADB() async -> URL? {
        if let adbURL { return adbURL }
        return await AndroidSDKLocator.locate().sdk?.adbURL
    }
}
