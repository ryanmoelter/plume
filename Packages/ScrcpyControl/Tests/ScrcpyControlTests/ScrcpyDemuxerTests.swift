import Foundation
import Testing
@testable import ScrcpyControl

/// Byte layouts from scrcpy 5.0.1's `Streamer.java` and `DesktopConnection.sendDeviceMeta`.
struct ScrcpyDemuxerTests {
    static func deviceMeta(_ name: String) -> Data {
        var data = Data(name.utf8)
        data.append(Data(count: 64 - data.count))
        return data
    }

    static func codec(_ id: UInt32) -> Data {
        var out = ByteWriter()
        out.u32(id)
        return out.data
    }

    static func session(width: UInt32, height: UInt32) -> Data {
        var out = ByteWriter()
        out.u32(0x8000_0000)
        out.u32(width)
        out.u32(height)
        return out.data
    }

    static func packet(_ payload: Data, ptsAndFlags: UInt64) -> Data {
        var out = ByteWriter()
        out.u64(ptsAndFlags)
        out.u32(UInt32(payload.count))
        out.data.append(payload)
        return out.data
    }

    static let config = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE])
    static let keyFrame = Data([0, 0, 0, 1, 0x65, 0x88, 0x84])
    static let deltaFrame = Data([0, 0, 0, 1, 0x41, 0x9A])

    static var stream: Data {
        deviceMeta("Pixel 9 Pro Fold")
            + codec(ScrcpyVideoCodec.h264)
            + session(width: 1080, height: 2424)
            + packet(config, ptsAndFlags: 1 << 62)
            + packet(keyFrame, ptsAndFlags: 1 << 61 | 1000)
            + packet(deltaFrame, ptsAndFlags: 17_000)
            + session(width: 2076, height: 2152)
            + packet(config, ptsAndFlags: 1 << 62)
            + packet(keyFrame, ptsAndFlags: 1 << 61 | 33_000)
    }

    static let expected: [ScrcpyDemuxerEvent] = [
        .deviceName("Pixel 9 Pro Fold"),
        .codec(ScrcpyVideoCodec.h264),
        .session(width: 1080, height: 2424),
        .config(config),
        .frame(keyFrame, pts: 1000, isKeyFrame: true),
        .frame(deltaFrame, pts: 17_000, isKeyFrame: false),
        .session(width: 2076, height: 2152),
        .config(config),
        .frame(keyFrame, pts: 33_000, isKeyFrame: true),
    ]

    @Test func parsesAWholeStream() throws {
        var demuxer = ScrcpyDemuxer()
        #expect(try demuxer.feed(Self.stream) == Self.expected)
    }

    @Test(arguments: [1, 2, 3, 5, 7, 11, 12, 13, 64, 65, 100])
    func parsesAcrossChunkBoundaries(chunkSize: Int) throws {
        var demuxer = ScrcpyDemuxer()
        let stream = Self.stream
        var events: [ScrcpyDemuxerEvent] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + chunkSize, stream.count)
            events += try demuxer.feed(stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(events == Self.expected)
    }

    @Test func waitsForAWholePayload() throws {
        var demuxer = ScrcpyDemuxer(expectsDeviceName: false)
        let packet = Self.packet(Self.keyFrame, ptsAndFlags: 1 << 61 | 5)
        #expect(try demuxer.feed(Self.codec(ScrcpyVideoCodec.h264) + packet.prefix(14)) == [.codec(ScrcpyVideoCodec.h264)])
        #expect(try demuxer.feed(packet.dropFirst(14)) == [.frame(Self.keyFrame, pts: 5, isKeyFrame: true)])
    }

    @Test func trimsTheDeviceNameAtItsTerminator() throws {
        var demuxer = ScrcpyDemuxer()
        #expect(try demuxer.feed(Self.deviceMeta("Café")) == [.deviceName("Café")])
    }

    @Test func rejectsADisabledStream() {
        var demuxer = ScrcpyDemuxer(expectsDeviceName: false)
        #expect(throws: ScrcpyDemuxerError.streamDisabled) { try demuxer.feed(Self.codec(0)) }
    }

    @Test func reportsAServerConfigurationError() {
        var demuxer = ScrcpyDemuxer(expectsDeviceName: false)
        #expect(throws: ScrcpyDemuxerError.serverConfigurationError) { try demuxer.feed(Self.codec(1)) }
    }

    @Test func rejectsAZeroSizedSession() {
        var demuxer = ScrcpyDemuxer(expectsDeviceName: false)
        #expect(throws: ScrcpyDemuxerError.invalidSession(width: 0, height: 2424)) {
            try demuxer.feed(Self.codec(ScrcpyVideoCodec.h264) + Self.session(width: 0, height: 2424))
        }
    }
}
