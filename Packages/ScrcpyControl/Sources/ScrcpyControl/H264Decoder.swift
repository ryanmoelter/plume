import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

public enum AnnexB {
    public enum NALType {
        public static let idr: UInt8 = 5
        public static let sps: UInt8 = 7
        public static let pps: UInt8 = 8
        public static let accessUnitDelimiter: UInt8 = 9
    }

    /// Splits an Annex B byte stream on 3- and 4-byte start codes. The returned units carry no start code.
    public static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let codeStart = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
                starts.append((codeStart, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        var units: [Data] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1].codeStart : bytes.count
            if end > start.payloadStart {
                units.append(Data(bytes[start.payloadStart..<end]))
            }
        }
        return units
    }

    public static func type(of unit: Data) -> UInt8 {
        guard let first = unit.first else { return 0 }
        return first & 0x1F
    }

    /// Each unit prefixed with its 4-byte big-endian length, as `CMSampleBuffer`s for H.264 expect.
    public static func avcc(_ units: [Data]) -> Data {
        var out = ByteWriter()
        for unit in units {
            out.u32(UInt32(unit.count))
            out.data.append(unit)
        }
        return out.data
    }
}

public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pixelSize: CGSize
    public let pts: UInt64
}

public enum H264DecoderError: Error, CustomStringConvertible {
    case formatDescription(OSStatus)
    case session(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)

    public var description: String {
        switch self {
        case let .formatDescription(status): "Could not build an H.264 format description (\(status))."
        case let .session(status): "Could not create a VideoToolbox decoder (\(status))."
        case let .sampleBuffer(status): "Could not wrap an H.264 frame (\(status))."
        case let .decode(status): "VideoToolbox failed to decode a frame (\(status))."
        }
    }
}

/// Decodes scrcpy's H.264 packets synchronously into IOSurface-backed BGRA pixel buffers.
/// Not thread-safe: one task feeds it.
public final class H264Decoder {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var awaitingKeyFrame = true

    public init() {}

    deinit {
        invalidateSession()
    }

    /// Takes the SPS and PPS from a config packet. The next decoded frame must be a key frame.
    /// A rejected config leaves no parameter sets, so frames are dropped until a usable one arrives
    /// rather than decoded against the previous stream's.
    public func configure(with config: Data) throws {
        awaitingKeyFrame = true
        do {
            try absorbParameterSets(from: AnnexB.split(config))
        } catch {
            sps = nil
            pps = nil
            formatDescription = nil
            throw error
        }
    }

    /// Drops frames until the next key frame, for a consumer that missed the frames in between.
    public func resynchronize() {
        awaitingKeyFrame = true
    }

    /// Returns nil for a frame that can't be shown yet: before any parameter sets, or a
    /// non-key frame while waiting for a key frame.
    public func decode(_ packet: Data, pts: UInt64, isKeyFrame: Bool) throws -> DecodedFrame? {
        var units = AnnexB.split(packet)
        try absorbParameterSets(from: units)
        units.removeAll { [AnnexB.NALType.sps, AnnexB.NALType.pps, AnnexB.NALType.accessUnitDelimiter].contains(AnnexB.type(of: $0)) }
        guard !units.isEmpty, let formatDescription else { return nil }

        let isKey = isKeyFrame || units.contains { AnnexB.type(of: $0) == AnnexB.NALType.idr }
        if awaitingKeyFrame {
            guard isKey else { return nil }
            awaitingKeyFrame = false
        }

        let session = try currentSession(for: formatDescription)
        let sample = try Self.sampleBuffer(AnnexB.avcc(units), format: formatDescription, pts: pts)
        let box = OutputBox()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            box.status = status
            box.imageBuffer = imageBuffer
        }
        if status != noErr {
            if status == kVTInvalidSessionErr {
                invalidateSession()
            }
            awaitingKeyFrame = true
            throw H264DecoderError.decode(status)
        }
        guard box.status == noErr, let imageBuffer = box.imageBuffer else {
            awaitingKeyFrame = true
            if box.status != noErr { throw H264DecoderError.decode(box.status) }
            return nil
        }
        let size = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        return DecodedFrame(pixelBuffer: imageBuffer, pixelSize: size, pts: pts)
    }

    private func absorbParameterSets(from units: [Data]) throws {
        var newSPS = sps
        var newPPS = pps
        for unit in units {
            switch AnnexB.type(of: unit) {
            case AnnexB.NALType.sps: newSPS = unit
            case AnnexB.NALType.pps: newPPS = unit
            default: break
            }
        }
        guard let newSPS, let newPPS, newSPS != sps || newPPS != pps else { return }
        sps = newSPS
        pps = newPPS
        formatDescription = try Self.formatDescription(sps: newSPS, pps: newPPS)
    }

    private func currentSession(for format: CMVideoFormatDescription) throws -> VTDecompressionSession {
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            return session
        }
        invalidateSession()
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw H264DecoderError.session(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return created
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    static func formatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { throw H264DecoderError.formatDescription(status) }
        return format
    }

    static func sampleBuffer(_ avcc: Data, format: CMVideoFormatDescription, pts: UInt64) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw H264DecoderError.sampleBuffer(status) }
        status = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { throw H264DecoderError.sampleBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw H264DecoderError.sampleBuffer(status) }
        return sample
    }
}

private final class OutputBox: @unchecked Sendable {
    var status: OSStatus = noErr
    var imageBuffer: CVImageBuffer?
}
