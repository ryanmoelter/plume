#if DEBUG
import AVFoundation
import AppKit
import QuartzCore

/// What one frame captures, in the window image's pixels. Built on the main
/// actor each tick, so a window that moves, resizes or gains an overlay is
/// followed; captured off it.
nonisolated struct RecordingFrameRequest: Sendable {
    var windowID: UInt32
    var overlayID: UInt32?
    var contentRect: CGRect
    /// Relative to `contentRect`, or nil for the whole content view.
    var targetRect: CGRect?
}

/// Records a window the way `screenshot` captures one: `WindowCapture` on a
/// timer, so no Screen Recording grant is needed and focus never moves.
/// One recording at a time per process. It stops itself at `maxSeconds`.
@MainActor
final class WindowRecorder {
    static let shared = WindowRecorder()

    private var active: Session?
    private var last: Task<RecordStopResult, Error>?

    private final class Session {
        let encoder: RecordingEncoder
        let source: () -> RecordingFrameRequest?
        let maxSeconds: Double
        let timer: DispatchSourceTimer
        /// A driven instance is never frontmost, and App Nap would otherwise
        /// stretch the timer to a few frames a second.
        let activity: NSObjectProtocol
        var inFlight = 0
        var dropped = 0

        init(encoder: RecordingEncoder, source: @escaping () -> RecordingFrameRequest?, maxSeconds: Double, timer: DispatchSourceTimer) {
            self.encoder = encoder
            self.source = source
            self.maxSeconds = maxSeconds
            self.timer = timer
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "control server recording")
        }
    }

    /// `firstFrame` is the capture the caller already checked for blankness;
    /// it becomes the frame at time zero and fixes the output size.
    func start(
        url: URL, firstFrame: CGImage, fps: Int, maxSeconds: Double,
        source: @escaping () -> RecordingFrameRequest?
    ) throws -> (width: Int, height: Int) {
        guard active == nil else { throw ControlError.unsupported("a recording is already running; send recordStop first") }
        let size = RecordingEncoder.outputSize(width: firstFrame.width, height: firstFrame.height)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let encoder = try RecordingEncoder(url: url, width: size.width, height: size.height, fps: fps, colorSpace: firstFrame.colorSpace)
        encoder.queue.sync { _ = encoder.append(firstFrame) }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let session = Session(encoder: encoder, source: source, maxSeconds: maxSeconds, timer: timer)
        timer.schedule(deadline: .now() + 1.0 / Double(fps), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        active = session
        last = nil
        timer.resume()
        return size
    }

    func stop() async throws -> RecordStopResult {
        if active != nil { finish(.request) }
        guard let last else { throw ControlError.notFound("recording; send recordStart first") }
        return try await last.value
    }

    private func tick() {
        guard let session = active else { return }
        if session.encoder.elapsed() >= session.maxSeconds {
            finish(.limit)
            return
        }
        guard let request = session.source() else {
            finish(.windowClosed)
            return
        }
        // Two frames queued is the most worth keeping: each is stamped when
        // it is captured, so a backlog only delays frames, never mistimes them.
        guard session.inFlight < 2 else {
            session.dropped += 1
            return
        }
        session.inFlight += 1
        let encoder = session.encoder
        encoder.queue.async {
            let appended = encoder.capture(request)
            DispatchQueue.main.async {
                session.inFlight -= 1
                if !appended { session.dropped += 1 }
            }
        }
    }

    private func finish(_ reason: RecordingStopReason) {
        guard let session = active else { return }
        active = nil
        session.timer.cancel()
        ProcessInfo.processInfo.endActivity(session.activity)
        let encoder = session.encoder
        last = Task { @MainActor in
            let summary = try await encoder.finish()
            // Frames still in flight when the timer stopped have landed by
            // now, since `finish` runs behind them on the same queue.
            return RecordStopResult(
                path: encoder.url.path(percentEncoded: false), width: encoder.width, height: encoder.height,
                frames: summary.frames, dropped: session.dropped, duration: summary.duration, stoppedBy: reason
            )
        }
    }
}

/// An H.264 writer fed `CGImage`s. Every method but `init`, `elapsed` and
/// `finish` must run on `queue`.
nonisolated final class RecordingEncoder: @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    let queue = DispatchQueue(label: "com.ryanmoelter.Plume.recording", qos: .userInitiated)

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let colorSpace: CGColorSpace
    private let startTime = CACurrentMediaTime()
    private var lastTime: Double = -1
    private var frames = 0

    /// H.264 needs even dimensions, and VideoToolbox refuses frames past
    /// 4096 on a side, so a large Retina window is scaled down to fit.
    static func outputSize(width: Int, height: Int, maxSide: Int = 4096) -> (width: Int, height: Int) {
        let factor = min(1, Double(maxSide) / Double(max(width, height, 1)))
        func even(_ value: Double) -> Int { max(2, Int(value) & ~1) }
        return (even(Double(width) * factor), even(Double(height) * factor))
    }

    /// `.mov` writes QuickTime; anything else writes MPEG-4.
    static func fileType(for url: URL) -> AVFileType {
        url.pathExtension.lowercased() == "mov" ? .mov : .mp4
    }

    /// Frames are drawn in the capture's own color space, because converting
    /// each one to another costs more than the whole rest of a frame; the
    /// video is tagged with primaries to match.
    init(url: URL, width: Int, height: Int, fps: Int, colorSpace: CGColorSpace? = nil) throws {
        let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.colorSpace = colorSpace
        self.url = url
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: Self.fileType(for: url))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: Self.isP3(colorSpace) ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: fps],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ControlError.io("the video writer refused its input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ControlError.io("could not start writing \(url.path): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func elapsed() -> Double {
        CACurrentMediaTime() - startTime
    }

    func capture(_ request: RecordingFrameRequest) -> Bool {
        guard var image = WindowCapture.image(windowID: request.windowID)?.cropping(to: request.contentRect) else { return false }
        if let overlayID = request.overlayID, let cursor = WindowCapture.image(windowID: overlayID) {
            image = WindowCapture.composite(cursor, over: image) ?? image
        }
        if let target = request.targetRect {
            guard let cropped = image.cropping(to: target) else { return false }
            image = cropped
        }
        return append(image)
    }

    /// Stamps the frame with the time it is appended, so the video plays at
    /// the speed the window changed.
    @discardableResult
    func append(_ image: CGImage) -> Bool {
        let time = frames == 0 ? 0 : elapsed()
        guard time > lastTime, input.isReadyForMoreMediaData, let buffer = pixelBuffer(drawing: image) else { return false }
        guard adaptor.append(buffer, withPresentationTime: Self.cmTime(time)) else { return false }
        lastTime = time
        frames += 1
        return true
    }

    /// Ends the video at the moment it stops, not at its last frame, so its
    /// duration is the time recorded even when the window sat still.
    func finish() async throws -> (frames: Int, duration: Double) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(frames: Int, duration: Double), Error>) in
            queue.async { [self] in
                guard frames > 0 else {
                    writer.cancelWriting()
                    continuation.resume(throwing: ControlError.io("no frames were captured"))
                    return
                }
                let end = max(elapsed(), lastTime + 0.001)
                input.markAsFinished()
                writer.endSession(atSourceTime: Self.cmTime(end))
                let count = frames
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: (count, end))
                    } else {
                        continuation.resume(throwing: ControlError.io("could not finish the video: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"))
                    }
                }
            }
        }
    }

    private static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600_000)
    }

    /// Aspect-fit on black, so a window resized mid-recording still fills
    /// the frame size fixed at the start.
    private func pixelBuffer(drawing image: CGImage) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: Self.aspectFit(CGSize(width: image.width, height: image.height), in: CGSize(width: width, height: height)))
        return buffer
    }

    static func isP3(_ colorSpace: CGColorSpace) -> Bool {
        guard let name = colorSpace.name as String? else { return false }
        return name.localizedCaseInsensitiveContains("P3")
    }

    static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * factor, height: size.height * factor)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}
#endif
