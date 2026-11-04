import Foundation
import Observation

/// Tracks physical devices adb can see. Polls only while retained, since adb has nothing to watch.
@MainActor @Observable
final class PhysicalDeviceDiscovery {
    static let shared = PhysicalDeviceDiscovery()
    static let pollInterval: Duration = .seconds(2)
    /// How long a failed serial-number read waits before a poll tries it again.
    static let serialRetryDelay: Duration = .seconds(8)

    private(set) var devices: [PhysicalDevice] = []
    private(set) var adbURL: URL?
    /// Each listed Wi-Fi device's `ro.serialno`, by adb serial.
    private(set) var hardwareSerials: [String: String] = [:]

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored let list: @Sendable () async -> ADBListing
    @ObservationIgnored private let serialNumber: @Sendable (_ adb: URL, _ serial: String) async -> String?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    /// Reads in flight or failed, by adb serial, for as long as adb lists it.
    @ObservationIgnored private var serialLookups: [String: SerialLookup] = [:]
    @ObservationIgnored private var startedRefreshes = 0
    @ObservationIgnored private var publishedRefresh = 0

    private enum SerialLookup {
        case running(Task<String?, Never>)
        case failed(at: ContinuousClock.Instant)
    }

    init(
        list: @escaping @Sendable () async -> ADBListing = ADBListing.live,
        serialNumber: @escaping @Sendable (_ adb: URL, _ serial: String) async -> String? = ADBWireless.serialNumber,
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.list = list
        self.serialNumber = serialNumber
        self.now = now
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

    /// Publishes the listing at once, then waits for the serial numbers of the published Wi-Fi
    /// devices. A listing older than one already published is dropped, so overlapping refreshes
    /// never go back, but its caller still waits for the newer listing's serial numbers.
    func refresh() async {
        startedRefreshes += 1
        let refresh = startedRefreshes
        let listing = await list()
        if refresh > publishedRefresh {
            publishedRefresh = refresh
            publish(listing)
        }
        await resolveListedHardwareSerials()
    }

    /// What a tab persists for the device at `serial`: `wifi:<ro.serialno>` for a Wi-Fi device
    /// once its serial number is known, else the adb serial.
    func identifier(forSerial serial: String) -> String {
        guard ADBWireless.isNetworkSerial(serial), let hardware = hardwareSerials[serial] else { return serial }
        return PhysicalDeviceIdentity.wifi(hardwareSerial: hardware)
    }

    /// Reads the serial number now when it isn't known, even when a recent read failed, for a
    /// caller that can't wait for a poll.
    func resolvedIdentifier(forSerial serial: String) async -> String {
        guard ADBWireless.isNetworkSerial(serial) else { return serial }
        if hardwareSerials[serial] == nil, let adb = await currentADB(),
           let lookup = startLookup(of: serial, adb: adb, retryingFailure: true) {
            await finish(lookup, of: serial)
        }
        return identifier(forSerial: serial)
    }

    /// The phone's serial number a tab identifier names, when known: the part after `wifi:`, a
    /// USB serial as is, or the read serial number of a Wi-Fi adb serial.
    func hardwareSerial(ofIdentifier identifier: String) -> String? {
        if PhysicalDeviceIdentity.isWifi(identifier) { return PhysicalDeviceIdentity.hardwareSerial(of: identifier) }
        return ADBWireless.isNetworkSerial(identifier) ? hardwareSerials[identifier] : identifier
    }

    /// Whether two tab identifiers name the same phone, over USB, Wi-Fi or both.
    func namesSamePhone(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard let hardware = hardwareSerial(ofIdentifier: first) else { return false }
        return hardware == hardwareSerial(ofIdentifier: second)
    }

    /// One row per phone: a phone adb lists twice, over USB and Wi-Fi or under both an mDNS name
    /// and an address, keeps its ready connection, preferring USB, then the mDNS name.
    func phones(in devices: [PhysicalDevice]) -> [PhysicalDevice] {
        func key(_ device: PhysicalDevice) -> String { hardwareSerial(ofIdentifier: device.serial) ?? device.serial }
        func rank(_ device: PhysicalDevice) -> Int {
            let transport = !device.isNetwork ? 0 : ADBWireless.address(device.serial) == nil ? 1 : 2
            return (device.isReady ? 0 : 3) + transport
        }
        var best: [String: PhysicalDevice] = [:]
        var order: [String] = []
        for device in devices {
            let key = key(device)
            if let current = best[key] {
                if rank(device) < rank(current) { best[key] = device }
            } else {
                best[key] = device
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
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
        let kept = hardwareSerials.filter { listed.contains($0.key) }
        if kept != hardwareSerials { hardwareSerials = kept }
        serialLookups = serialLookups.filter { listed.contains($0.key) }
    }

    private func resolveListedHardwareSerials() async {
        guard let adb = adbURL else { return }
        let lookups = devices.filter { $0.isNetwork && $0.isReady }.compactMap { device in
            startLookup(of: device.serial, adb: adb, retryingFailure: false).map { (device.serial, $0) }
        }
        for (serial, lookup) in lookups { await finish(lookup, of: serial) }
    }

    /// The read to wait on: one already running, or a new one unless the serial number is known
    /// or a read failed too recently.
    private func startLookup(of serial: String, adb: URL, retryingFailure: Bool) -> Task<String?, Never>? {
        guard hardwareSerials[serial] == nil else { return nil }
        switch serialLookups[serial] {
        case .running(let lookup):
            return lookup
        case .failed(let at) where !retryingFailure && now() - at < Self.serialRetryDelay:
            return nil
        case .failed, nil:
            let lookup = Task { [serialNumber] in await serialNumber(adb, serial) }
            serialLookups[serial] = .running(lookup)
            return lookup
        }
    }

    private func finish(_ lookup: Task<String?, Never>, of serial: String) async {
        let hardware = await lookup.value
        // A lookup dropped while it ran belongs to a connection adb no longer lists.
        guard case .running(let current) = serialLookups[serial], current == lookup else { return }
        if let hardware {
            serialLookups[serial] = nil
            hardwareSerials[serial] = hardware
        } else {
            serialLookups[serial] = .failed(at: now())
        }
    }

    private func currentADB() async -> URL? {
        if let adbURL { return adbURL }
        return await AndroidSDKLocator.locate().sdk?.adbURL
    }
}
