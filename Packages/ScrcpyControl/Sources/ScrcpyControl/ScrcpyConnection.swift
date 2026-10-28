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
            let video = try await openVideoSocket(port: port)
            videoSocket = video
            let control = LocalSocket(port: port, label: "control")
            try await control.open()
            controlSocket = control

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
            await tearDown(error: error)
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

    private var serial: String { launch.serial }

    private func tearDown(error: Error?) async {
        guard !closed else { return }
        closed = true
        controlContinuation.finish()
        for task in tasks { task.cancel() }
        tasks = []
        videoSocket?.close()
        controlSocket?.close()
        videoSocket = nil
        controlSocket = nil
        hub.finish(throwing: error)
        await launch.stop()
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
        tasks.append(Task.detached { [weak self] in
            var demuxer = demuxer
            let decoder = H264Decoder()
            do {
                try Self.handle(pending, decoder: decoder, hub: hub)
                while !Task.isCancelled {
                    guard let chunk = try await video.receive() else { break }
                    try Self.handle(demuxer.feed(chunk), decoder: decoder, hub: hub)
                }
                await self?.streamEnded(nil)
            } catch {
                await self?.streamEnded(Task.isCancelled ? nil : error)
            }
        })
    }

    private static func handle(_ events: [ScrcpyDemuxerEvent], decoder: H264Decoder, hub: FrameHub) throws {
        for event in events {
            switch event {
            case let .session(width, height):
                hub.setVideoSize(CGSize(width: width, height: height))
            case let .config(data):
                try decoder.configure(with: data)
            case let .frame(data, pts, isKeyFrame):
                guard hub.wantsFrames() else {
                    decoder.resynchronize()
                    continue
                }
                do {
                    if let decoded = try decoder.decode(data, pts: pts, isKeyFrame: isKeyFrame) {
                        hub.publish(decoded)
                    }
                } catch is H264DecoderError {
                    // A corrupt or unsupported frame costs a frame, not the session; the decoder waits for the next key frame.
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
