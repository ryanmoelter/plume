import CoreGraphics
import Foundation
import Testing
@testable import ScrcpyControl

struct ScrcpyHandshakeTests {
    private typealias Bytes = ScrcpyDemuxerTests

    @Test func aSecondSessionInTheFirstChunkReachesThePump() throws {
        var demuxer = ScrcpyDemuxer()
        var handshake = ScrcpyHandshake()
        let chunk = Bytes.deviceMeta("Pixel")
            + Bytes.codec(ScrcpyVideoCodec.h264)
            + Bytes.session(width: 1080, height: 2424)
            + Bytes.session(width: 2424, height: 1080)
            + Bytes.packet(Bytes.config, ptsAndFlags: 1 << 62)
        try handshake.absorb(demuxer.feed(chunk))

        #expect(handshake.deviceName == "Pixel")
        #expect(handshake.initialSize == CGSize(width: 1080, height: 2424))
        #expect(handshake.pending == [.session(width: 2424, height: 1080), .config(Bytes.config)])
    }

    @Test func aNonH264CodecFails() throws {
        var demuxer = ScrcpyDemuxer()
        var handshake = ScrcpyHandshake()
        let chunk = Bytes.deviceMeta("Pixel") + Bytes.codec(ScrcpyVideoCodec.h265)
        #expect(throws: (any Error).self) { try handshake.absorb(demuxer.feed(chunk)) }
    }
}
