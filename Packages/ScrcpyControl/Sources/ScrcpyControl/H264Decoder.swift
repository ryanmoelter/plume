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
        data.withUnsafeBytes { bytes in unitRanges(in: bytes).map { Data(bytes[$0]) } }
    }

    /// Each unit's payload range in `bytes`, without its start code. Empty units are left out.
    static func unitRanges(in bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        guard bytes.count >= 3, let base = bytes.baseAddress else { return [] }
        var ranges: [Range<Int>] = []
        var payloadStart: Int?
        var searchFrom = 2
        // A start code ends in a 0x01 after two zeros, so a memchr for 0x01 skips most of the
        // packet without a byte-by-byte scan.
        while searchFrom < bytes.count, let hit = memchr(base + searchFrom, 1, bytes.count - searchFrom) {
            let one = base.distance(to: UnsafeRawPointer(hit))
            searchFrom = one + 1
            guard bytes[one - 1] == 0, bytes[one - 2] == 0 else { continue }
            let codeStart = one >= 3 && bytes[one - 3] == 0 ? one - 3 : one - 2
            if let payloadStart, codeStart > payloadStart {
                ranges.append(payloadStart..<codeStart)
            }
            payloadStart = one + 1
            searchFrom = one + 3
        }
        if let payloadStart, bytes.count > payloadStart {
            ranges.append(payloadStart..<bytes.count)
        }
        return ranges
    }

    public static func type(of unit: Data) -> UInt8 {
        guard let first = unit.first else { return 0 }
        return first & 0x1F
    }

    static func type(of unit: Range<Int>, in bytes: UnsafeRawBufferPointer) -> UInt8 {
        bytes[unit.lowerBound] & 0x1F
    }

    static func avccLength(of units: [Range<Int>]) -> Int {
        units.reduce(0) { $0 + 4 + $1.count }
    }

    /// Writes each unit prefixed with its 4-byte big-endian length, as `CMSampleBuffer`s for H.264
    /// expect. `destination` holds exactly `avccLength(of: units)` bytes.
    static func writeAVCC(_ units: [Range<Int>], from bytes: UnsafeRawBufferPointer, to destination: UnsafeMutableRawPointer) {
        var offset = 0
        for unit in units {
            destination.storeBytes(of: UInt32(unit.count).bigEndian, toByteOffset: offset, as: UInt32.self)
            offset += 4
            destination.advanced(by: offset).copyMemory(from: bytes.baseAddress! + unit.lowerBound, byteCount: unit.count)
            offset += unit.count
        }
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
    case noImage

    public var description: String {
        switch self {
        case let .formatDescription(status): "Could not build an H.264 format description (\(status))."
        case let .session(status): "Could not create a VideoToolbox decoder (\(status))."
        case let .sampleBuffer(status): "Could not wrap an H.264 frame (\(status))."
        case let .decode(status): "VideoToolbox failed to decode a frame (\(status))."
        case .noImage: "VideoToolbox decoded a frame but produced no image."
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
    /// non-key frame while waiting for a key frame. Throws for a frame that should have decoded
    /// and didn't, so the caller can ask for a key frame.
    public func decode(_ packet: Data, pts: UInt64, isKeyFrame: Bool) throws -> DecodedFrame? {
        let sample: CMSampleBuffer? = try packet.withUnsafeBytes { bytes in
            var units = AnnexB.unitRanges(in: bytes)
            try absorbParameterSets(from: units.compactMap { unit in
                Self.isParameterSet(AnnexB.type(of: unit, in: bytes)) ? Data(bytes[unit]) : nil
            })
            units.removeAll { Self.isOutOfBand(AnnexB.type(of: $0, in: bytes)) }
            guard !units.isEmpty, let formatDescription else { return nil }

            let isKey = isKeyFrame || units.contains { AnnexB.type(of: $0, in: bytes) == AnnexB.NALType.idr }
            if awaitingKeyFrame {
                guard isKey else { return nil }
                awaitingKeyFrame = false
            }
            return try Self.sampleBuffer(units, in: bytes, format: formatDescription, pts: pts)
        }
        guard let sample, let formatDescription else { return nil }

        let session = try currentSession(for: formatDescription)
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
        // A frame VideoToolbox drops without an error still breaks the reference chain, so it
        // throws: returning nil would leave the stream waiting for a key frame nobody asked for.
        guard box.status == noErr, let imageBuffer = box.imageBuffer else {
            awaitingKeyFrame = true
            throw box.status == noErr ? H264DecoderError.noImage : H264DecoderError.decode(box.status)
        }
        let size = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        return DecodedFrame(pixelBuffer: imageBuffer, pixelSize: size, pts: pts)
    }

    private static func isParameterSet(_ type: UInt8) -> Bool {
        type == AnnexB.NALType.sps || type == AnnexB.NALType.pps
    }

    /// Units the format description carries, or that a sample must not.
    private static func isOutOfBand(_ type: UInt8) -> Bool {
        isParameterSet(type) || type == AnnexB.NALType.accessUnitDelimiter
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

    /// Copies the units straight into the block buffer as AVCC, the packet's only copy.
    static func sampleBuffer(_ units: [Range<Int>], in bytes: UnsafeRawBufferPointer, format: CMVideoFormatDescription, pts: UInt64) throws -> CMSampleBuffer {
        let length = AnnexB.avccLength(of: units)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw H264DecoderError.sampleBuffer(status) }
        var destination: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &destination)
        guard status == noErr, let destination else { throw H264DecoderError.sampleBuffer(status) }
        AnnexB.writeAVCC(units, from: bytes, to: UnsafeMutableRawPointer(destination))

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
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
