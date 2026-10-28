import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

public struct ScrcpyFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let surface: IOSurfaceRef?
    public let pixelSize: CGSize
    /// The size input positions must be expressed against (`ScrcpyPosition.screenWidth/Height`).
    public let videoSize: CGSize
    public let seq: UInt64
}

public enum ScrcpyConnectionError: Error, CustomStringConvertible {
    case closed
    case disconnected
    case unsupportedCodec(UInt32)

    public var description: String {
        switch self {
        case .closed: "The scrcpy connection is closed."
        case .disconnected: "The device disconnected."
        case let .unsupportedCodec(codec): "scrcpy-server chose codec 0x\(String(codec, radix: 16)), not H.264."
        }
    }
}

/// One mirroring session with a physical device through scrcpy-server.
public actor ScrcpyConnection {
    private static let connectDeadline: Duration = .seconds(10)
    private static let connectRetryDelay: Duration = .milliseconds(100)

    private let launch: ScrcpyServerLaunch
    private let hub = FrameHub()
    private nonisolated let controlStream: AsyncStream<Data>
    private nonisolated let controlContinuation: AsyncStream<Data>.Continuation
    private var videoSocket: LocalSocket?
    private var controlSocket: LocalSocket?
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    public init(adbURL: URL, serial: String, jarURL: URL, version: String) {
        launch = ScrcpyServerLaunch(adbURL: adbURL, serial: serial, jarURL: jarURL, version: version)
        (controlStream, controlContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(512))
    }

    /// The current capture size, which changes when the device rotates or folds.
    public nonisolated var videoSize: CGSize? { hub.videoSize }

    public func connect() async throws -> (deviceName: String, initialSize: CGSize) {
        guard !closed, videoSocket == nil else { throw ScrcpyConnectionError.closed }
        do {
            let port = try await launch.start()
            if closed { throw ScrcpyConnectionError.closed }
            videoSocket = try await openVideoSocket(port: port)
            if closed { throw ScrcpyConnectionError.closed }
            let control = LocalSocket(port: port, label: "control")
            controlSocket = control
            try await control.open()
            guard let video = videoSocket, !closed else { throw ScrcpyConnectionError.closed }

            var demuxer = ScrcpyDemuxer()
            var deviceName: String?
            var initialSize: CGSize?
            var pending: [ScrcpyDemuxerEvent] = []
            while initialSize == nil {
                guard let chunk = try await video.receive() else {
                    throw launch.exitError ?? ScrcpyConnectionError.disconnected
                }
                for event in try demuxer.feed(chunk) {
                    switch event {
                    case let .deviceName(name):
                        deviceName = name
                    case let .codec(codec) where codec != ScrcpyVideoCodec.h264:
                        throw ScrcpyConnectionError.unsupportedCodec(codec)
                    case let .session(width, height) where initialSize == nil:
                        initialSize = CGSize(width: width, height: height)
                        hub.setVideoSize(initialSize!)
                    case .codec, .session:
                        break
                    default:
                        pending.append(event)
                    }
                }
            }
            if closed { throw ScrcpyConnectionError.closed }
            startPump(video: video, demuxer: demuxer, pending: pending)
            startControl(control)
            return (deviceName ?? serial, initialSize!)
        } catch {
            // A close() that ran while connect was suspended already tore down, so tearDown is a
            // no-op here; release what was created since.
            await tearDown(error: error)
            closeSockets()
            await launch.stop()
            throw error
        }
    }

    /// One consumer at a time; a new call finishes the previous stream. The stream throws when the
    /// device disconnects or the server exits, and finishes on `close()`.
    public nonisolated func frames() -> AsyncThrowingStream<ScrcpyFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScrcpyFrame.self, bufferingPolicy: .bufferingNewest(1))
        if hub.attach(continuation) {
            send(.resetVideo)
        }
        return stream
    }

    public nonisolated func send(_ message: ScrcpyControlMessage) {
        controlContinuation.yield(message.encoded())
    }

    public func close() async {
        await tearDown(error: nil)
    }

    /// Starts stopping the server and removing the forward, and returns at once.
    /// `ScrcpyServerLaunch.awaitTerminations()` waits for it; `close()` still tears down the rest.
    public nonisolated func terminate() {
        controlContinuation.finish()
        launch.terminate()
    }

    private var serial: String { launch.serial }

    private func tearDown(error: Error?) async {
        guard !closed else { return }
        closed = true
        controlContinuation.finish()
        for task in tasks { task.cancel() }
        tasks = []
        closeSockets()
        hub.finish(throwing: error)
        await launch.stop()
    }

    private func closeSockets() {
        videoSocket?.close()
        controlSocket?.close()
        videoSocket = nil
        controlSocket = nil
    }

    private func streamEnded(_ error: Error?) async {
        guard !closed else { return }
        await tearDown(error: error ?? launch.exitError ?? ScrcpyConnectionError.disconnected)
    }

    /// The adb forward accepts at once even when the server isn't listening yet, and then closes;
    /// the dummy byte proves the server accepted.
    private func openVideoSocket(port: UInt16) async throws -> LocalSocket {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.connectDeadline
        while true {
            if closed { throw ScrcpyConnectionError.closed }
            if let exit = launch.exitError { throw exit }
            let socket = LocalSocket(port: port, label: "video")
            do {
                try await socket.open()
                if let dummy = try await socket.receive(exactly: 1), dummy.count == 1 {
                    return socket
                }
            } catch {}
            socket.close()
            guard clock.now < deadline else { throw ScrcpyLaunchError.connectTimedOut }
            try await Task.sleep(for: Self.connectRetryDelay)
        }
    }

    private func startPump(video: LocalSocket, demuxer: ScrcpyDemuxer, pending: [ScrcpyDemuxerEvent]) {
        let hub = hub
        let control = controlContinuation
        tasks.append(Task.detached { [weak self] in
            var demuxer = demuxer
            let decoder = H264Decoder()
            var recovery = KeyFrameRecovery { control.yield(ScrcpyControlMessage.resetVideo.encoded()) }
            do {
                Self.handle(pending, decoder: decoder, hub: hub, recovery: &recovery)
                while !Task.isCancelled {
                    guard let chunk = try await video.receive() else { break }
                    Self.handle(try demuxer.feed(chunk), decoder: decoder, hub: hub, recovery: &recovery)
                }
                await self?.streamEnded(nil)
            } catch {
                await self?.streamEnded(Task.isCancelled ? nil : error)
            }
        })
    }

    /// A rejected config or a corrupt frame costs frames, not the session: the decoder waits for
    /// the next key frame and the server is asked for one.
    private static func handle(_ events: [ScrcpyDemuxerEvent], decoder: H264Decoder, hub: FrameHub, recovery: inout KeyFrameRecovery) {
        for event in events {
            switch event {
            case let .session(width, height):
                hub.setVideoSize(CGSize(width: width, height: height))
            case let .config(data):
                do {
                    try decoder.configure(with: data)
                } catch {
                    recovery.decoderFailed()
                }
            case let .frame(data, pts, isKeyFrame):
                guard hub.wantsFrames() else {
                    decoder.resynchronize()
                    continue
                }
                do {
                    if let decoded = try decoder.decode(data, pts: pts, isKeyFrame: isKeyFrame) {
                        recovery.decoded()
                        hub.publish(decoded)
                    } else {
                        recovery.frameDropped()
                    }
                } catch {
                    recovery.decoderFailed()
                }
            case .deviceName, .codec:
                break
            }
        }
    }

    private func startControl(_ control: LocalSocket) {
        let stream = controlStream
        tasks.append(Task.detached {
            for await message in stream {
                do {
                    try await control.send(message)
                } catch {
                    break
                }
            }
        })
        tasks.append(Task.detached {
            var parser = ScrcpyDeviceMessageParser()
            while !Task.isCancelled {
                guard let chunk = try? await control.receive() else { break }
                _ = parser.feed(chunk)
            }
        })
    }
}

/// Asks the server for a key frame after a decode failure, at most once per `interval`, until a
/// frame decodes again.
struct KeyFrameRecovery {
    static let interval: Duration = .seconds(1)

    private let request: () -> Void
    private let now: () -> ContinuousClock.Instant
    private var isRecovering = false
    private var lastRequest: ContinuousClock.Instant?

    init(now: @escaping () -> ContinuousClock.Instant = { .now }, request: @escaping () -> Void) {
        self.now = now
        self.request = request
    }

    mutating func decoderFailed() {
        isRecovering = true
        requestIfDue()
    }

    mutating func frameDropped() {
        if isRecovering { requestIfDue() }
    }

    mutating func decoded() {
        isRecovering = false
    }

    private mutating func requestIfDue() {
        let time = now()
        if let lastRequest, time - lastRequest < Self.interval { return }
        lastRequest = time
        request()
    }
}

/// Hands decoded frames to the current consumer. Lock-protected because the pump, `frames()` and
/// stream termination all reach it from different contexts.
private final class FrameHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ScrcpyFrame, Error>.Continuation?
    private var consumerID = 0
    private var finished = false
    private var terminalError: Error?
    private var skippedFrames = false
    private var currentVideoSize: CGSize?
    private var seq: UInt64 = 0

    var videoSize: CGSize? { lock.withLock { currentVideoSize } }

    func setVideoSize(_ size: CGSize) {
        lock.withLock { currentVideoSize = size }
    }

    /// Returns true when frames were dropped while nobody watched, so the caller should ask for a key frame.
    func attach(_ newContinuation: AsyncThrowingStream<ScrcpyFrame, Error>.Continuation) -> Bool {
        let (previous, id, done, error, needsKeyFrame) = lock.withLock {
            let previous = continuation
            consumerID += 1
            if !finished { continuation = newContinuation }
            let needsKeyFrame = skippedFrames
            skippedFrames = false
            return (previous, consumerID, finished, terminalError, needsKeyFrame)
        }
        previous?.finish()
        if done {
            newContinuation.finish(throwing: error)
            return false
        }
        newContinuation.onTermination = { [weak self] _ in self?.detach(id) }
        return needsKeyFrame
    }

    private func detach(_ id: Int) {
        lock.withLock {
            if consumerID == id { continuation = nil }
        }
    }

    func wantsFrames() -> Bool {
        lock.withLock {
            if continuation == nil { skippedFrames = true }
            return continuation != nil
        }
    }

    func publish(_ frame: DecodedFrame) {
        let target = lock.withLock { () -> (AsyncThrowingStream<ScrcpyFrame, Error>.Continuation, ScrcpyFrame)? in
            guard let continuation else { return nil }
            seq &+= 1
            let videoSize = currentVideoSize ?? frame.pixelSize
            let out = ScrcpyFrame(
                pixelBuffer: frame.pixelBuffer,
                surface: CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue(),
                pixelSize: frame.pixelSize,
                videoSize: videoSize,
                seq: seq
            )
            return (continuation, out)
        }
        if let (continuation, frame) = target {
            continuation.yield(frame)
        }
    }

    func finish(throwing error: Error?) {
        let current = lock.withLock { () -> AsyncThrowingStream<ScrcpyFrame, Error>.Continuation? in
            finished = true
            terminalError = error
            defer { continuation = nil }
            return continuation
        }
        current?.finish(throwing: error)
    }
}
