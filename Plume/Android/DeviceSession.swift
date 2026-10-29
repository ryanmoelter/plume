import CoreGraphics
import EmulatorControl
import Foundation
import Observation
import ScrcpyControl

/// Receives frames on the main actor. Frames bypass observation entirely, so a
/// streaming device never invalidates a SwiftUI view.
@MainActor
protocol DeviceFrameSink: AnyObject {
    var requestedPixelSize: CGSize { get }
    func present(_ frame: DeviceFrame)
}

enum DeviceSessionState: Equatable {
    case needsDevice
    case locating
    case notRunning
    case booting
    case connecting
    case connected
    /// A physical device that is ready but unconnected because no sink watches it. The next sink connects.
    case suspended
    case disconnected(String)
    case failed(String)
    /// Waiting for Device Streaming to reserve a remote device and activate it.
    case reserving
    /// The remote device's reservation ended, by expiry, inactivity or the user.
    case reservationEnded
    /// A Device Streaming command failed, before or after the reservation existed.
    case reservationFailed(String)
}

extension ScrcpyVideoLimits {
    /// A remote device streams over the internet, so it sends less than a USB one.
    nonisolated static let remoteDevice = ScrcpyVideoLimits(maxSize: 1280, videoBitRate: 4_000_000, maxFps: 30)
}

/// One tab's link to one device. It streams frames only while a sink is
/// attached, and closing it never stops an emulator.
@MainActor
@Observable
final class DeviceSession {
    /// How long a physical device stays connected after its last sink leaves. Reconnecting costs
    /// about a second, which a quick tab switch shouldn't pay; a phone encoding for a hidden tab
    /// costs battery and heat.
    static let physicalIdleStopDelay: Duration = .seconds(5)
    /// How often a remote tab asks whether its reservation is still active, which catches an end
    /// from inactivity.
    static let reservationPollInterval: TimeInterval = 60
    /// Past the local expiry the service may not have ended the reservation yet, so the monitor keeps asking, no faster than this.
    static let reservationMinimumPoll: TimeInterval = 15
    static let extendMinutes = 15

    let tabID: UUID
    private(set) var target: DeviceTarget?
    private(set) var displayName: String?
    private(set) var state: DeviceSessionState {
        didSet {
            guard state != oldValue else { return }
            EmulatorLog.info("\(logPrefix) state \(oldValue) -> \(state)")
        }
    }
    /// Natural-orientation device pixels, the space touches are sent in.
    private(set) var deviceSize: CGSize?
    private(set) var rotation: DeviceRotation = .portrait
    private(set) var isStreaming = false
    /// The remote device's reservation, kept after it ends so the view can still read it.
    private(set) var reservation: RemoteReservation?
    private(set) var remoteDetails: RemoteDeviceDetails?
    private(set) var isExtending = false
    var extendError: String?

    /// Called when the user picks a device, so the tab can persist it.
    @ObservationIgnored var onDeviceChange: ((_ target: DeviceTarget?, _ displayName: String?) -> Void)?
    @ObservationIgnored var onRemoteDetailsChange: ((RemoteDeviceDetails?) -> Void)?

    @ObservationIgnored private let discovery: EmulatorDiscovery
    @ObservationIgnored private let physicalDiscovery: PhysicalDeviceDiscovery
    @ObservationIgnored private let makeConnection: (ResolvedDevice) -> DeviceConnecting
    @ObservationIgnored private let idleSleep: (Duration) async -> Void
    @ObservationIgnored private var connection: DeviceConnecting?
    /// What `connection` was made for, so a suspended session can reconnect without a fresh lookup.
    @ObservationIgnored private var connectedDevice: ResolvedDevice?
    @ObservationIgnored private var sinks: [ObjectIdentifier: WeakSink] = [:]
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamPixelSize: CGSize = .zero
    @ObservationIgnored private var idleStopTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrame: DeviceFrame?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let remoteCLI: AndroidCLIRunning
    @ObservationIgnored private let ledger: RemoteReservationLedger
    @ObservationIgnored private let reservationSleep: (Duration) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var reservationMonitor: Task<Void, Never>?

    init(
        tabID: UUID,
        target: DeviceTarget?,
        displayName: String? = nil,
        remoteDetails: RemoteDeviceDetails? = nil,
        discovery: EmulatorDiscovery = .shared,
        physicalDiscovery: PhysicalDeviceDiscovery = .shared,
        makeConnection: @escaping (ResolvedDevice) -> DeviceConnecting = DeviceSession.liveConnection,
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        remoteCLI: AndroidCLIRunning = AndroidCLI.shared,
        ledger: RemoteReservationLedger = .shared,
        reservationSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.tabID = tabID
        self.target = target
        self.displayName = displayName
        self.discovery = discovery
        self.physicalDiscovery = physicalDiscovery
        self.makeConnection = makeConnection
        self.idleSleep = idleSleep
        self.remoteCLI = remoteCLI
        self.ledger = ledger
        self.reservationSleep = reservationSleep
        self.now = now
        state = target == nil ? .needsDevice : .locating
        // A quit ends every reservation, so a remote tab from an earlier run only offers Reserve Again.
        if case .remote = target {
            self.remoteDetails = remoteDetails
            state = .reservationEnded
        }
    }

    nonisolated static func liveConnection(for device: ResolvedDevice) -> DeviceConnecting {
        switch device {
        case .emulator(let emulator): EmulatorDeviceConnection(emulator: emulator)
        case .physical(let serial, let adbURL, let videoLimits):
            PhysicalDeviceConnection(serial: serial, adbURL: adbURL, videoLimits: videoLimits)
        }
    }

    var isConnected: Bool { state == .connected }
    var isPhysical: Bool { target?.isPhysical == true || isRemote }
    var isRemote: Bool {
        if case .remote = target { return true }
        return state == .reserving || remoteDetails != nil
    }
    var canShutDownEmulator: Bool { isConnected && !isPhysical }
    /// Whether the reservation is still billed and can be extended or ended.
    var hasLiveReservation: Bool { reservation.map { !$0.isReleased && $0.reservationID != nil } ?? false }
    /// Also true while `create` runs, which ending cancels.
    var canEndReservation: Bool { hasLiveReservation || state == .reserving }
    /// The adb serial a live reservation attached, which the picker leaves out of its device list.
    var remoteSerial: String? { reservation?.serial }

    private var logPrefix: String { "tab \(tabID.uuidString.prefix(8)) [\(target?.identifier ?? "no device")]" }

    /// Reattaches to the tab's device if it is already running. Never boots one.
    func start() {
        guard !started else { return }
        started = true
        locate()
    }

    func locate() {
        locate(waitingForSink: true)
    }

    /// `waitingForSink` false is for the picker, whose own view is no sink but is about to be replaced by one.
    private func locate(waitingForSink: Bool) {
        guard let target else {
            state = .needsDevice
            return
        }
        if case .remote = target, reservation == nil || reservation?.isReleased == true {
            state = .reservationEnded
            return
        }
        state = .locating
        runWork { [weak self] in
            guard let self else { return }
            switch target {
            case .emulator(let avdID):
                await discovery.refresh()
                guard !Task.isCancelled else { return }
                if let running = discovery.running.first(where: { $0.avdID == avdID && $0.grpcToken != nil }) {
                    connect(to: .emulator(running))
                } else {
                    state = .notRunning
                }
            case .physical(let serial):
                await physicalDiscovery.refresh()
                guard !Task.isCancelled else { return }
                if let adbURL = physicalDiscovery.adbURL,
                   physicalDiscovery.devices.contains(where: { $0.serial == serial && $0.isReady }) {
                    let device = ResolvedDevice.physical(serial: serial, adbURL: adbURL)
                    if hasSinks || !waitingForSink {
                        connect(to: device)
                    } else {
                        // A hidden tab would start the phone's encoder only to stop it after the grace period.
                        connectedDevice = device
                        state = .suspended
                    }
                } else {
                    state = .notRunning
                }
            case .remote:
                guard let reservation, !reservation.isReleased else { return }
                switch await reservation.status() {
                case .ended:
                    reservationDidEnd(reservation)
                case .unknown(let message):
                    guard self.reservation === reservation else { return }
                    state = .reservationFailed(message)
                    startReservationMonitor(reservation)
                case .active:
                    await attachReservation(reservation, waitingForSink: waitingForSink)
                }
            }
        }
    }

    // MARK: Remote devices

    func reserve(_ model: RemoteDeviceModel, projectID: String) {
        reserve(details: RemoteDeviceDetails(projectID: projectID, model: model.id), displayName: model.name)
    }

    /// Reserves the same model again after a reservation ended or failed.
    func reserveAgain() {
        guard let remoteDetails, remoteDetails.model != nil else { return }
        reserve(details: RemoteDeviceDetails(projectID: remoteDetails.projectID, model: remoteDetails.model), displayName: displayName)
    }

    private func reserve(details: RemoteDeviceDetails, displayName: String?) {
        workTask?.cancel()
        workTask = nil
        stopReservationMonitor()
        disconnect()
        reservation?.release()
        let reservation = RemoteReservation(
            projectID: details.projectID, model: details.model, cli: remoteCLI, ledger: ledger, now: now
        )
        self.reservation = reservation
        remoteDetails = details
        self.displayName = displayName
        state = .reserving
        EmulatorLog.info("\(logPrefix) reserving \(details.model ?? "?") in \(details.projectID)")
        runWork { [weak self] in
            do {
                try await reservation.create()
            } catch {
                guard let self, self.reservation === reservation, !(error is CancellationError) else { return }
                EmulatorLog.error("\(logPrefix) reserving failed: \(error.localizedDescription)")
                // A create that printed an id before failing still holds a billed reservation.
                reservation.release()
                state = .reservationFailed(error.localizedDescription)
                return
            }
            guard let self, self.reservation === reservation, !Task.isCancelled, !reservation.isReleased,
                  let id = reservation.reservationID
            else { return }
            choose(.remote(reservationID: id), displayName: displayName)
            // Cleared so the tab persists the details even when they match what was requested.
            remoteDetails = nil
            updateRemoteDetails(from: reservation)
            await attachReservation(reservation, waitingForSink: false)
        }
    }

    /// Connects an active reservation to adb, then streams it like a USB device.
    private func attachReservation(_ reservation: RemoteReservation, waitingForSink: Bool) async {
        updateRemoteDetails(from: reservation)
        startReservationMonitor(reservation)
        let serial: String
        do {
            serial = try await reservation.connect()
        } catch {
            guard self.reservation === reservation, !Task.isCancelled else { return }
            state = .reservationFailed(error.localizedDescription)
            return
        }
        await physicalDiscovery.refresh()
        guard self.reservation === reservation, !Task.isCancelled else { return }
        guard let adbURL = physicalDiscovery.adbURL else {
            state = .reservationFailed("adb wasn't found.")
            return
        }
        let device = ResolvedDevice.physical(serial: serial, adbURL: adbURL, videoLimits: .remoteDevice)
        if hasSinks || !waitingForSink {
            connect(to: device)
        } else {
            connectedDevice = device
            state = .suspended
        }
    }

    func extendReservation(minutes: Int = DeviceSession.extendMinutes) {
        guard let reservation, hasLiveReservation, !isExtending else { return }
        isExtending = true
        Task { [weak self] in
            do {
                try await reservation.extend(minutes: minutes)
                guard let self, self.reservation === reservation else { return }
                updateRemoteDetails(from: reservation)
                startReservationMonitor(reservation)
            } catch {
                EmulatorLog.error("extending the reservation failed: \(error.localizedDescription)")
                self?.extendError = error.localizedDescription
            }
            self?.isExtending = false
        }
    }

    /// Ends the reservation now. The tab keeps its device, so it can reserve the same model again.
    func endReservation() {
        guard let reservation else { return }
        EmulatorLog.info("\(logPrefix) ending the reservation")
        workTask?.cancel()
        workTask = nil
        reservationDidEnd(reservation)
    }

    private func reservationDidEnd(_ ended: RemoteReservation) {
        guard reservation === ended else { return }
        stopReservationMonitor()
        disconnect()
        ended.release()
        state = .reservationEnded
    }

    private func updateRemoteDetails(from reservation: RemoteReservation) {
        let details = RemoteDeviceDetails(projectID: reservation.projectID, model: reservation.model, expiresAt: reservation.expiresAt)
        guard details != remoteDetails else { return }
        remoteDetails = details
        onRemoteDetailsChange?(details)
    }

    /// Wakes at the expiry, or every poll interval if that's sooner, and asks the service.
    private func startReservationMonitor(_ reservation: RemoteReservation) {
        reservationMonitor?.cancel()
        reservationMonitor = Task { [weak self, reservationSleep, now] in
            while !Task.isCancelled {
                let untilExpiry = reservation.expiresAt.map { $0.timeIntervalSince(now()) } ?? Self.reservationPollInterval
                await reservationSleep(.seconds(min(Self.reservationPollInterval, max(Self.reservationMinimumPoll, untilExpiry))))
                guard !Task.isCancelled, !reservation.isReleased else { return }
                let status = await reservation.status()
                guard !Task.isCancelled, let self, self.reservation === reservation else { return }
                if status == .ended {
                    EmulatorLog.info("\(logPrefix) the reservation ended")
                    reservationDidEnd(reservation)
                    return
                }
                updateRemoteDetails(from: reservation)
            }
        }
    }

    private func stopReservationMonitor() {
        reservationMonitor?.cancel()
        reservationMonitor = nil
    }

    func attach(_ emulator: RunningEmulator) {
        choose(.emulator(avdID: emulator.avdID), displayName: emulator.avdName)
        connect(to: .emulator(emulator))
    }

    /// Connects without listing adb again, since the picker just did.
    func attach(_ device: PhysicalDevice) {
        choose(.physical(serial: device.serial), displayName: device.displayName)
        guard let adbURL = physicalDiscovery.adbURL else {
            locate(waitingForSink: false)
            return
        }
        connect(to: .physical(serial: device.serial, adbURL: adbURL))
    }

    func boot(_ avd: AVD) {
        choose(.emulator(avdID: avd.id), displayName: avd.displayName)
        bootChosenDevice()
    }

    func bootChosenDevice() {
        guard case .emulator(let avdID) = target else { return }
        state = .booting
        runWork { [weak self] in
            guard let self else { return }
            guard let sdk = await AndroidSDKLocator.locate().sdk else {
                state = .failed("No Android SDK was found.")
                return
            }
            let launch: EmulatorLaunch
            do {
                launch = try EmulatorLauncher.boot(avdID: avdID, sdk: sdk)
                EmulatorLog.info("\(logPrefix) booting, launcher pid \(launch.pid), log \(launch.logURL.path)")
            } catch {
                EmulatorLog.error("\(logPrefix) boot failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                return
            }
            await waitForBoot(avdID: avdID, launch: launch)
        }
    }

    /// Polls rather than retaining the discovery watcher: a boot is the only
    /// thing waiting, and it gives up on its own.
    private func waitForBoot(avdID: String, launch: EmulatorLaunch) async {
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            await discovery.refresh()
            if let running = discovery.running.first(where: { isBoot(of: launch, avdID: avdID, $0) }) {
                connect(to: .emulator(running))
                return
            }
            if launch.hasExited {
                let tail = launch.logTail(lines: 6)
                state = .failed(tail.isEmpty ? "The emulator exited during boot." : tail)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !Task.isCancelled {
            state = .failed("The emulator did not start within three minutes. Its log is at \(launch.logURL.path).")
        }
    }

    /// A file older than the launch belongs to an instance still shutting down.
    private func isBoot(of launch: EmulatorLaunch, avdID: String, _ emulator: RunningEmulator) -> Bool {
        guard emulator.avdID == avdID, emulator.grpcToken != nil else { return false }
        guard let written = EmulatorScanner.modificationDate(of: emulator) else { return false }
        return written >= launch.launchedAt.addingTimeInterval(-1)
    }

    /// Forgets the device so the tab shows the picker again.
    func changeDevice() {
        workTask?.cancel()
        workTask = nil
        stopReservationMonitor()
        disconnect()
        reservation?.release()
        reservation = nil
        remoteDetails = nil
        choose(nil, displayName: nil)
        state = .needsDevice
    }

    func shutDownEmulator() {
        guard !isPhysical, let connection else { return }
        EmulatorLog.info("\(logPrefix) shutting down the emulator")
        workTask?.cancel()
        workTask = nil
        stopStreaming()
        self.connection = nil
        state = .notRunning
        Task {
            try? await connection.shutDown()
            await connection.close()
        }
    }

    func close() {
        EmulatorLog.info("\(logPrefix) closing the session")
        workTask?.cancel()
        workTask = nil
        sinks.removeAll()
        stopReservationMonitor()
        disconnect()
        reservation?.release()
    }

    /// Like `close()`, but never waits on the connection, for app termination.
    func terminate() {
        workTask?.cancel()
        workTask = nil
        sinks.removeAll()
        stopReservationMonitor()
        stopStreaming()
        connection?.terminate()
        connection = nil
        reservation?.release(concurrently: true)
    }

    // MARK: Sinks

    func addSink(_ sink: DeviceFrameSink) {
        sinks[ObjectIdentifier(sink)] = WeakSink(sink)
        if streamTask != nil, let lastFrame { sink.present(lastFrame) }
        updateStreaming()
    }

    func removeSink(_ sink: DeviceFrameSink) {
        sinks[ObjectIdentifier(sink)] = nil
        updateStreaming()
    }

    /// A sink's size changed; restart the stream if the largest request moved.
    func sinkSizeChanged() {
        updateStreaming()
    }

    // MARK: Input

    func send(_ input: DeviceInput) {
        guard isConnected else { return }
        connection?.send(input)
    }

    func press(_ button: DeviceButton) {
        guard isConnected, let connection else { return }
        connection.press(button, phase: .down)
        connection.press(button, phase: .up)
    }

    func rotate(clockwise: Bool) {
        guard isConnected, let connection else { return }
        let next = rotation.rotated(clockwise: clockwise)
        runWork {
            try? await connection.rotate(to: next)
        }
    }

    // MARK: Private

    private func choose(_ target: DeviceTarget?, displayName: String?) {
        guard target != self.target || displayName != self.displayName else { return }
        self.target = target
        self.displayName = displayName
        onDeviceChange?(target, displayName)
    }

    private func connect(to device: ResolvedDevice) {
        disconnect()
        state = .connecting
        let connection = makeConnection(device)
        self.connection = connection
        connectedDevice = device
        switch device {
        case .emulator(let emulator):
            EmulatorLog.info("\(logPrefix) connecting to qemu pid \(emulator.pid) on port \(emulator.grpcPort)")
        case .physical(let serial, _, _):
            EmulatorLog.info("\(logPrefix) connecting to \(serial) through scrcpy-server")
        }
        runWork { [weak self] in
            do {
                let info = try await connection.connect()
                guard let self, self.connection === connection else { return }
                deviceSize = info.deviceSize
                // Physical frames arrive already rotated; an emulator's rotation is real and outlives a reconnect.
                if case .physical = device { rotation = .portrait }
                EmulatorLog.info("\(logPrefix) connected, display \(String(describing: info.deviceSize))")
                state = .connected
                updateStreaming()
            } catch {
                guard let self, self.connection === connection else { return }
                lose(connection, reason: error.localizedDescription)
            }
        }
    }

    private func disconnect() {
        stopStreaming()
        guard let connection else { return }
        self.connection = nil
        // Starting the release here, not in the task, means a quit straight after still waits for it.
        connection.terminate()
        Task { await connection.close() }
    }

    private func lose(_ lost: DeviceConnecting, reason: String) {
        guard connection === lost else { return }
        EmulatorLog.error("\(logPrefix) lost the connection: \(reason)")
        disconnect()
        state = .disconnected(reason)
        // A remote device drops off adb when its reservation ends.
        if let reservation, !reservation.isReleased {
            runWork { [weak self] in
                guard await reservation.status() == .ended else { return }
                self?.reservationDidEnd(reservation)
            }
        }
    }

    private var hasSinks: Bool {
        sinks.values.contains { $0.sink != nil }
    }

    private func updateStreaming() {
        sinks = sinks.filter { $0.value.sink != nil }
        let sinks = sinks.values.compactMap(\.sink)
        if state == .suspended, !sinks.isEmpty, let connectedDevice {
            EmulatorLog.info("\(logPrefix) a sink returned, reconnecting")
            connect(to: connectedDevice)
            return
        }
        guard isConnected, let connection else {
            stopStreaming()
            return
        }
        guard !sinks.isEmpty else {
            if isPhysical { scheduleIdleStop() } else { stopStreaming() }
            return
        }
        cancelIdleStop()
        let size = sinks.map(\.requestedPixelSize).reduce(CGSize.zero) {
            CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
        }
        guard size.width >= 1, size.height >= 1 else {
            stopStreaming()
            return
        }
        // A physical device streams at its native size and the layer scales it.
        if streamTask != nil, size == streamPixelSize || isPhysical { return }
        stopStreaming()
        streamPixelSize = size
        isStreaming = true
        EmulatorLog.info("\(logPrefix) streaming at \(Int(size.width))x\(Int(size.height)) to \(sinks.count) sink(s)")
        let frames = connection.frames(maxPixelSize: size)
        streamTask = Task { [weak self] in
            var isFirstFrame = true
            do {
                for try await frame in frames {
                    guard let self else { return }
                    if isFirstFrame {
                        isFirstFrame = false
                        EmulatorLog.info("\(logPrefix) first frame \(Int(frame.pixelSize.width))x\(Int(frame.pixelSize.height))")
                    }
                    present(frame)
                }
                guard !Task.isCancelled else { return }
                self?.lose(connection, reason: "The device stopped sending frames.")
            } catch {
                guard !Task.isCancelled else { return }
                self?.lose(connection, reason: error.localizedDescription)
            }
        }
    }

    private func present(_ frame: DeviceFrame) {
        if frame.rotation != rotation { rotation = frame.rotation }
        if let size = frame.deviceSize, size != deviceSize { deviceSize = size }
        lastFrame = frame
        for entry in sinks.values { entry.sink?.present(frame) }
    }

    private func scheduleIdleStop() {
        guard idleStopTask == nil else { return }
        EmulatorLog.info("\(logPrefix) no sinks, closing the connection in \(Self.physicalIdleStopDelay)")
        idleStopTask = Task { [weak self, idleSleep] in
            await idleSleep(Self.physicalIdleStopDelay)
            guard !Task.isCancelled, let self else { return }
            idleStopTask = nil
            suspend()
        }
    }

    private func suspend() {
        guard isConnected else { return }
        EmulatorLog.info("\(logPrefix) suspending until a sink returns")
        disconnect()
        state = .suspended
    }

    private func cancelIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = nil
    }

    private func stopStreaming() {
        cancelIdleStop()
        if streamTask != nil { EmulatorLog.info("\(logPrefix) stopped streaming") }
        streamTask?.cancel()
        streamTask = nil
        streamPixelSize = .zero
        lastFrame = nil
        if isStreaming { isStreaming = false }
    }

    private func runWork(_ operation: @escaping @MainActor () async -> Void) {
        workTask?.cancel()
        workTask = Task { await operation() }
    }
}

private struct WeakSink {
    weak var sink: DeviceFrameSink?
    init(_ sink: DeviceFrameSink) { self.sink = sink }
}

extension DeviceRotation {
    nonisolated init(_ rotation: EmulatorRotation) {
        switch rotation {
        case .portrait: self = .portrait
        case .landscape: self = .landscape
        case .reversePortrait: self = .reversePortrait
        case .reverseLandscape: self = .reverseLandscape
        }
    }

    nonisolated var emulatorRotation: EmulatorRotation {
        switch self {
        case .portrait: .portrait
        case .landscape: .landscape
        case .reversePortrait: .reversePortrait
        case .reverseLandscape: .reverseLandscape
        }
    }

    /// Landscape is the portrait device turned counter-clockwise.
    func rotated(clockwise: Bool) -> DeviceRotation {
        let counterClockwise: [DeviceRotation] = [.portrait, .landscape, .reversePortrait, .reverseLandscape]
        let index = counterClockwise.firstIndex(of: self) ?? 0
        let step = clockwise ? counterClockwise.count - 1 : 1
        return counterClockwise[(index + step) % counterClockwise.count]
    }
}
