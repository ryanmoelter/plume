import CoreGraphics
import EmulatorControl
import Foundation
import Observation

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
    case disconnected(String)
    case failed(String)
}

/// One tab's link to one device. It streams frames only while a sink is
/// attached, and closing it never stops an emulator.
@MainActor
@Observable
final class DeviceSession {
    /// How long a physical device keeps streaming after its last sink leaves. Restarting
    /// scrcpy's encoder costs a key frame and a visible stall, which a quick tab switch shouldn't pay.
    static let physicalIdleStopDelay: Duration = .seconds(5)

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

    /// Called when the user picks a device, so the tab can persist it.
    @ObservationIgnored var onDeviceChange: ((_ target: DeviceTarget?, _ displayName: String?) -> Void)?

    @ObservationIgnored private let discovery: EmulatorDiscovery
    @ObservationIgnored private let physicalDiscovery: PhysicalDeviceDiscovery
    @ObservationIgnored private let makeConnection: (ResolvedDevice) -> DeviceConnecting
    @ObservationIgnored private let idleSleep: (Duration) async -> Void
    @ObservationIgnored private var connection: DeviceConnecting?
    @ObservationIgnored private var sinks: [ObjectIdentifier: WeakSink] = [:]
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamPixelSize: CGSize = .zero
    @ObservationIgnored private var idleStopTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrame: DeviceFrame?
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(
        tabID: UUID,
        target: DeviceTarget?,
        displayName: String? = nil,
        discovery: EmulatorDiscovery = .shared,
        physicalDiscovery: PhysicalDeviceDiscovery = .shared,
        makeConnection: @escaping (ResolvedDevice) -> DeviceConnecting = DeviceSession.liveConnection,
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.tabID = tabID
        self.target = target
        self.displayName = displayName
        self.discovery = discovery
        self.physicalDiscovery = physicalDiscovery
        self.makeConnection = makeConnection
        self.idleSleep = idleSleep
        state = target == nil ? .needsDevice : .locating
    }

    nonisolated static func liveConnection(for device: ResolvedDevice) -> DeviceConnecting {
        switch device {
        case .emulator(let emulator): EmulatorDeviceConnection(emulator: emulator)
        case .physical(let serial, let adbURL): PhysicalDeviceConnection(serial: serial, adbURL: adbURL)
        }
    }

    var isConnected: Bool { state == .connected }
    var isPhysical: Bool { target?.isPhysical == true }
    var canShutDownEmulator: Bool { isConnected && !isPhysical }

    private var logPrefix: String { "tab \(tabID.uuidString.prefix(8)) [\(target?.identifier ?? "no device")]" }

    /// Reattaches to the tab's device if it is already running. Never boots one.
    func start() {
        guard !started else { return }
        started = true
        locate()
    }

    func locate() {
        guard let target else {
            state = .needsDevice
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
                    connect(to: .physical(serial: serial, adbURL: adbURL))
                } else {
                    state = .notRunning
                }
            }
        }
    }

    func attach(_ emulator: RunningEmulator) {
        choose(.emulator(avdID: emulator.avdID), displayName: emulator.avdName)
        connect(to: .emulator(emulator))
    }

    func attach(_ device: PhysicalDevice) {
        choose(.physical(serial: device.serial), displayName: device.displayName)
        locate()
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
        disconnect()
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
        disconnect()
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
        switch device {
        case .emulator(let emulator):
            EmulatorLog.info("\(logPrefix) connecting to qemu pid \(emulator.pid) on port \(emulator.grpcPort)")
        case .physical(let serial, _):
            EmulatorLog.info("\(logPrefix) connecting to \(serial) through scrcpy-server")
        }
        runWork { [weak self] in
            do {
                let info = try await connection.connect()
                guard let self, self.connection === connection else { return }
                deviceSize = info.deviceSize
                rotation = .portrait
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
        Task { await connection.close() }
    }

    private func lose(_ lost: DeviceConnecting, reason: String) {
        guard connection === lost else { return }
        EmulatorLog.error("\(logPrefix) lost the connection: \(reason)")
        disconnect()
        state = .disconnected(reason)
    }

    private func updateStreaming() {
        sinks = sinks.filter { $0.value.sink != nil }
        let sinks = sinks.values.compactMap(\.sink)
        guard isConnected, let connection else {
            stopStreaming()
            return
        }
        guard !sinks.isEmpty else {
            if isPhysical, streamTask != nil { scheduleIdleStop() } else { stopStreaming() }
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
        EmulatorLog.info("\(logPrefix) no sinks, stopping the stream in \(Self.physicalIdleStopDelay)")
        idleStopTask = Task { [weak self, idleSleep] in
            await idleSleep(Self.physicalIdleStopDelay)
            guard !Task.isCancelled, let self else { return }
            idleStopTask = nil
            stopStreaming()
        }
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
