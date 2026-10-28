import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import ScrcpyControl

struct AnnexBTests {
    @Test func splitsOnThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC, 0, 0, 0, 1, 0x65])
        #expect(AnnexB.split(stream) == [Data([0x67, 0xAA]), Data([0x68, 0xBB, 0xCC]), Data([0x65])])
    }

    @Test func keepsZerosInsideAUnit() {
        let stream = Data([0, 0, 1, 0x41, 0x00, 0x00, 0x03, 0x00, 0x05])
        #expect(AnnexB.split(stream) == [Data([0x41, 0x00, 0x00, 0x03, 0x00, 0x05])])
    }

    @Test func ignoresBytesBeforeTheFirstStartCode() {
        #expect(AnnexB.split(Data([0xFF, 0, 0, 1, 0x65])) == [Data([0x65])])
        #expect(AnnexB.split(Data([0x65, 0x01])).isEmpty)
    }

    @Test func readsTheUnitType() {
        #expect(AnnexB.type(of: Data([0x67])) == AnnexB.NALType.sps)
        #expect(AnnexB.type(of: Data([0x65])) == AnnexB.NALType.idr)
    }

    @Test func prefixesEachUnitWithItsLength() {
        let avcc = AnnexB.avcc([Data([0x65, 0x01]), Data([0x41])])
        #expect([UInt8](avcc) == [0, 0, 0, 2, 0x65, 0x01, 0, 0, 0, 1, 0x41])
    }
}

/// Round-trips real H.264 from VideoToolbox's encoder through the decoder, framed the way scrcpy
/// sends it: SPS and PPS in a config packet, then Annex B frames.
struct H264DecoderTests {
    @Test func decodesEncodedFramesToIOSurfaceBackedBuffers() throws {
        let (config, frames) = try Self.encode(width: 320, height: 240, count: 3)
        let decoder = H264Decoder()
        try decoder.configure(with: config)

        var decoded: [DecodedFrame] = []
        for (index, frame) in frames.enumerated() {
            if let output = try decoder.decode(frame.data, pts: UInt64(index * 16_000), isKeyFrame: frame.isKey) {
                decoded.append(output)
            }
        }
        #expect(decoded.count == 3)
        let first = try #require(decoded.first)
        #expect(first.pixelSize == CGSize(width: 320, height: 240))
        #expect(CVPixelBufferGetPixelFormatType(first.pixelBuffer) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(first.pixelBuffer) != nil)
    }

    @Test func dropsDeltaFramesUntilAKeyFrame() throws {
        let (config, frames) = try Self.encode(width: 320, height: 240, count: 2)
        let decoder = H264Decoder()
        try decoder.configure(with: config)
        #expect(try decoder.decode(frames[1].data, pts: 0, isKeyFrame: false) == nil)
        #expect(try decoder.decode(frames[0].data, pts: 1, isKeyFrame: true) != nil)
    }

    @Test func rebuildsForNewParameterSets() throws {
        let decoder = H264Decoder()
        let (portraitConfig, portrait) = try Self.encode(width: 240, height: 320, count: 1)
        try decoder.configure(with: portraitConfig)
        #expect(try decoder.decode(portrait[0].data, pts: 0, isKeyFrame: true)?.pixelSize == CGSize(width: 240, height: 320))

        let (landscapeConfig, landscape) = try Self.encode(width: 320, height: 240, count: 1)
        try decoder.configure(with: landscapeConfig)
        #expect(try decoder.decode(landscape[0].data, pts: 1, isKeyFrame: true)?.pixelSize == CGSize(width: 320, height: 240))
    }

    @Test func aRejectedConfigDropsFramesInsteadOfDecodingAgainstTheOldOne() throws {
        let (config, frames) = try Self.encode(width: 320, height: 240, count: 1)
        let decoder = H264Decoder()
        try decoder.configure(with: config)
        let garbage = Data([0, 0, 0, 1, 0x67, 0xFF, 0, 0, 0, 1, 0x68, 0xFF])
        #expect(throws: H264DecoderError.self) { try decoder.configure(with: garbage) }
        #expect(try decoder.decode(frames[0].data, pts: 0, isKeyFrame: true) == nil)

        try decoder.configure(with: config)
        #expect(try decoder.decode(frames[0].data, pts: 1, isKeyFrame: true) != nil)
    }

    @Test func waitsForParameterSets() throws {
        let (_, frames) = try Self.encode(width: 320, height: 240, count: 1)
        #expect(try H264Decoder().decode(frames[0].data, pts: 0, isKeyFrame: true) == nil)
    }

    struct EncodedFrame {
        var data: Data
        var isKey: Bool
    }

    private final class Collector: @unchecked Sendable {
        var samples: [CMSampleBuffer] = []
    }

    static func encode(width: Int, height: Int, count: Int) throws -> (config: Data, frames: [EncodedFrame]) {
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        let encoder = try #require(session, "VTCompressionSessionCreate failed: \(status)")
        defer { VTCompressionSessionInvalidate(encoder) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        let collector = Collector()
        for index in 0..<count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(index * 60), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            status = VTCompressionSessionEncodeFrame(
                encoder,
                imageBuffer: pixels,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { _, _, sample in
                if let sample { collector.samples.append(sample) }
            }
            #expect(status == noErr)
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)

        let first = try #require(collector.samples.first)
        let format = try #require(CMSampleBufferGetFormatDescription(first))
        var config = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            config.append(contentsOf: [0, 0, 0, 1])
            config.append(UnsafeBufferPointer(start: try #require(pointer), count: size))
        }

        let frames = try collector.samples.map { sample in
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var avcc = Data(count: CMBlockBufferGetDataLength(block))
            avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            var annexB = Data()
            var offset = 0
            while offset + 4 <= avcc.count {
                let length = Int(avcc.readU32(at: offset))
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(avcc.subdata(in: offset + 4..<offset + 4 + length))
                offset += 4 + length
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            return EncodedFrame(data: annexB, isKey: !notSync)
        }
        return (config, frames)
    }
}
