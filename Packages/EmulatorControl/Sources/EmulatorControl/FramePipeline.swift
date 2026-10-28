import CoreGraphics
import Darwin
import Foundation
import GRPCCore

/// A file the emulator writes frames into when the MMAP transport is requested. Rows arrive top-down. The client owns
/// the file and the handle; frames may tear while the emulator is mid-write.
final class SharedFrameBuffer: @unchecked Sendable {
    let path: String
    let byteCount: Int
    private var base: UnsafeMutableRawPointer?
    private let descriptor: Int32

    init(byteCount: Int) throws {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("plume-emu-\(UUID().uuidString).rgba")
        self.byteCount = byteCount
        descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(descriptor)
            unlink(path)
            throw POSIXError(code)
        }
        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapped, mapped != MAP_FAILED else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(descriptor)
            unlink(path)
            throw POSIXError(code)
        }
        base = mapped
    }

    var handle: String { "file://" + path }

    func bytes(count: Int) -> UnsafeRawBufferPointer? {
        guard let base, count <= byteCount else { return nil }
        return UnsafeRawBufferPointer(start: base, count: count)
    }

    func close() {
        guard let mapped = base else { return }
        base = nil
        munmap(mapped, byteCount)
        Darwin.close(descriptor)
        unlink(path)
    }

    deinit { close() }
}

enum FramePipeline {
    private struct FallBackToBytes: Error {}

    static func run(
        client: EmulatorClient,
        maxPixelSize: CGSize,
        useSharedMemory: Bool,
        options: CallOptions,
        continuation: AsyncThrowingStream<EmulatorFrame, Error>.Continuation
    ) async throws {
        let width = UInt32(max(1, maxPixelSize.width.rounded()))
        let height = UInt32(max(1, maxPixelSize.height.rounded()))

        if useSharedMemory {
            do {
                let buffer = try SharedFrameBuffer(byteCount: Int(width) * Int(height) * 4)
                defer { buffer.close() }
                try await stream(client, width, height, buffer, options, continuation)
                return
            } catch is FallBackToBytes {
            } catch let error as RPCError where error.code == .failedPrecondition || error.code == .unimplemented {
            } catch is POSIXError {
            }
        }
        try await stream(client, width, height, nil, options, continuation)
    }

    private static func stream(
        _ client: EmulatorClient,
        _ width: UInt32,
        _ height: UInt32,
        _ buffer: SharedFrameBuffer?,
        _ options: CallOptions,
        _ continuation: AsyncThrowingStream<EmulatorFrame, Error>.Continuation
    ) async throws {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = width
        format.height = height
        if let buffer {
            var transport = Android_Emulation_Control_ImageTransport()
            transport.channel = .mmap
            transport.handle = buffer.handle
            format.transport = transport
        }

        try await client.streamScreenshot(request: ClientRequest(message: format), options: options) { response in
            var isFirst = true
            for try await image in response.messages {
                if let buffer, isFirst, isBlank(image, buffer) { throw FallBackToBytes() }
                isFirst = false
                if let frame = makeFrame(image, buffer) {
                    continuation.yield(frame)
                }
            }
        }
    }

    private static func isBlank(_ image: Android_Emulation_Control_Image, _ buffer: SharedFrameBuffer) -> Bool {
        let count = Int(image.format.width) * Int(image.format.height) * 4
        guard count > 0, let bytes = buffer.bytes(count: count) else { return true }
        return !bytes.contains { $0 != 0 }
    }

    private static func makeFrame(_ image: Android_Emulation_Control_Image, _ buffer: SharedFrameBuffer?) -> EmulatorFrame? {
        let width = Int(image.format.width)
        let height = Int(image.format.height)
        let rowBytes = width * 4
        guard width > 0, height > 0 else { return nil }

        let source: UnsafeRawBufferPointer
        if let buffer {
            guard let bytes = buffer.bytes(count: rowBytes * height) else { return nil }
            source = bytes
        } else {
            guard image.image.count >= rowBytes * height else { return nil }
            return image.image.withUnsafeBytes { frame(from: $0, width, height, image) }
        }
        return frame(from: source, width, height, image)
    }

    private static func frame(
        from source: UnsafeRawBufferPointer,
        _ width: Int,
        _ height: Int,
        _ image: Android_Emulation_Control_Image
    ) -> EmulatorFrame? {
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { destination in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: rowBytes * height)
        }
        guard
            let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }
        return EmulatorFrame(
            image: cgImage,
            pixelSize: CGSize(width: width, height: height),
            rotation: EmulatorRotation(image.format.rotation.rotation),
            seq: image.seq
        )
    }
}

extension EmulatorRotation {
    init(_ rotation: Android_Emulation_Control_Rotation.SkinRotation) {
        switch rotation {
        case .landscape: self = .landscape
        case .reversePortrait: self = .reversePortrait
        case .reverseLandscape: self = .reverseLandscape
        default: self = .portrait
        }
    }

    /// Degrees about the z axis for the ROTATION physical model.
    var zDegrees: Float {
        switch self {
        case .portrait: 0
        case .landscape: 90
        case .reversePortrait: 180
        case .reverseLandscape: -90
        }
    }
}
