import CoreGraphics
import EmulatorControl
import Foundation
import Observation

/// Receives frames on the main actor. Frames bypass observation entirely, so a
/// streaming device never invalidates a SwiftUI view.
@MainActor
protocol EmulatorFrameSink: AnyObject {
    var requestedPixelSize: CGSize { get }
    func present(_ frame: EmulatorFrame)
}

enum EmulatorSessionState: Equatable {
    case needsDevice
    case locating
    case notRunning
    case booting
    case connecting
    case connected
    case disconnected(String)
    case failed(String)
}

/// One tab's link to one emulator. It streams frames only while a sink is
/// attached, and closing it never stops the emulator.
@MainActor
@Observable
final class EmulatorSession {
    let tabID: UUID
    private(set) var avdID: String?
    private(set) var displayName: String?
    private(set) var state: EmulatorSessionState
    /// Natural-orientation device pixels, the space touches are sent in.
    private(set) var deviceSize: CGSize?
    private(set) var rotation: DeviceRotation = .portrait
    private(set) var isStreaming = false

    /// Called when the user picks a device, so the tab can persist it.
    @ObservationIgnored var onDeviceChange: ((_ avdID: String?, _ displayName: String?) -> Void)?

    @ObservationIgnored private let discovery: EmulatorDiscovery
    @ObservationIgnored private let makeConnection: (RunningEmulator) -> EmulatorConnecting
    @ObservationIgnored private var connection: EmulatorConnecting?
    @ObservationIgnored private var sinks: [ObjectIdentifier: WeakSink] = [:]
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamPixelSize: CGSize = .zero
    @ObservationIgnored private var workTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(
        tabID: UUID,
        avdID: String?,
        displayName: String? = nil,
        discovery: EmulatorDiscovery = .shared,
        makeConnection: @escaping (RunningEmulator) -> EmulatorConnecting = EmulatorSession.liveConnection
    ) {
        self.tabID = tabID
        self.avdID = avdID
        self.displayName = displayName
        self.discovery = discovery
        self.makeConnection = makeConnection
        state = avdID == nil ? .needsDevice : .locating
    }

    nonisolated static func liveConnection(for emulator: RunningEmulator) -> EmulatorConnecting {
        EmulatorConnection(endpoint: EmulatorEndpoint(port: emulator.grpcPort, token: emulator.grpcToken))
    }

    var isConnected: Bool { state == .connected }

    /// Reattaches to the tab's device if it is already running. Never boots one.
    func start() {
        guard !started else { return }
        started = true
        locate()
    }

    func locate() {
        guard let avdID else {
            state = .needsDevice
            return
        }
        state = .locating
        runWork { [weak self] in
            guard let self else { return }
            await discovery.refresh()
            guard !Task.isCancelled else { return }
            if let running = discovery.running.first(where: { $0.avdID == avdID && $0.grpcToken != nil }) {
                connect(to: running)
            } else {
                state = .notRunning
            }
        }
    }

    func attach(_ emulator: RunningEmulator) {
        choose(avdID: emulator.avdID, displayName: emulator.avdName)
        connect(to: emulator)
    }

    func boot(_ avd: AVD) {
        choose(avdID: avd.id, displayName: avd.displayName)
        bootChosenDevice()
    }

    func bootChosenDevice() {
        guard let avdID else { return }
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
            } catch {
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
                connect(to: running)
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
        choose(avdID: nil, displayName: nil)
        state = .needsDevice
    }

    func shutDownEmulator() {
        guard let connection else { return }
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
        workTask?.cancel()
        workTask = nil
        sinks.removeAll()
        disconnect()
    }

    // MARK: Sinks

    func addSink(_ sink: EmulatorFrameSink) {
        sinks[ObjectIdentifier(sink)] = WeakSink(sink)
        updateStreaming()
    }

    func removeSink(_ sink: EmulatorFrameSink) {
        sinks[ObjectIdentifier(sink)] = nil
        updateStreaming()
    }

    /// A sink's size changed; restart the stream if the largest request moved.
    func sinkSizeChanged() {
        updateStreaming()
    }

    // MARK: Input

    func send(_ input: EmulatorInput) {
        guard isConnected else { return }
        connection?.send(input)
    }

    func press(_ button: HardwareButton) {
        guard isConnected, let connection else { return }
        connection.press(button, phase: .down)
        connection.press(button, phase: .up)
    }

    func rotate(clockwise: Bool) {
        guard isConnected, let connection else { return }
        let next = rotation.rotated(clockwise: clockwise)
        runWork {
            try? await connection.rotate(to: next.emulatorRotation)
        }
    }

    // MARK: Private

    private func choose(avdID: String?, displayName: String?) {
        guard avdID != self.avdID || displayName != self.displayName else { return }
        self.avdID = avdID
        self.displayName = displayName
        onDeviceChange?(avdID, displayName)
    }

    private func connect(to emulator: RunningEmulator) {
        disconnect()
        state = .connecting
        let connection = makeConnection(emulator)
        self.connection = connection
        runWork { [weak self] in
            do {
                let status = try await connection.status()
                guard let self, self.connection === connection else { return }
                deviceSize = status.displaySize
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

    private func lose(_ lost: EmulatorConnecting, reason: String) {
        guard connection === lost else { return }
        disconnect()
        state = .disconnected(reason)
    }

    private func updateStreaming() {
        sinks = sinks.filter { $0.value.sink != nil }
        let sinks = sinks.values.compactMap(\.sink)
        guard isConnected, let connection, !sinks.isEmpty else {
            stopStreaming()
            return
        }
        let size = sinks.map(\.requestedPixelSize).reduce(CGSize.zero) {
            CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
        }
        guard size.width >= 1, size.height >= 1 else {
            stopStreaming()
            return
        }
        if streamTask != nil, size == streamPixelSize { return }
        stopStreaming()
        streamPixelSize = size
        isStreaming = true
        let frames = connection.frames(maxPixelSize: size)
        streamTask = Task { [weak self] in
            do {
                for try await frame in frames {
                    guard let self else { return }
                    let rotation = DeviceRotation(frame.rotation)
                    if rotation != self.rotation { self.rotation = rotation }
                    for entry in self.sinks.values { entry.sink?.present(frame) }
                }
                guard !Task.isCancelled else { return }
                self?.lose(connection, reason: "The emulator stopped sending frames.")
            } catch {
                guard !Task.isCancelled else { return }
                self?.lose(connection, reason: error.localizedDescription)
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        streamPixelSize = .zero
        if isStreaming { isStreaming = false }
    }

    private func runWork(_ operation: @escaping @MainActor () async -> Void) {
        workTask?.cancel()
        workTask = Task { await operation() }
    }
}

private struct WeakSink {
    weak var sink: EmulatorFrameSink?
    init(_ sink: EmulatorFrameSink) { self.sink = sink }
}

extension DeviceRotation {
    init(_ rotation: EmulatorRotation) {
        switch rotation {
        case .portrait: self = .portrait
        case .landscape: self = .landscape
        case .reversePortrait: self = .reversePortrait
        case .reverseLandscape: self = .reverseLandscape
        }
    }

    var emulatorRotation: EmulatorRotation {
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
