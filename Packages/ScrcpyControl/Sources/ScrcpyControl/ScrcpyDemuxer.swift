import Foundation

/// The scrcpy-server release this package speaks. The server refuses any other client version,
/// and the wire format changes between releases, so the vendored jar must match it.
public enum ScrcpyServerVersion {
    public static let pinned = "5.0.1"
}

public enum ScrcpyVideoCodec {
    public static let h264: UInt32 = 0x6832_3634
    public static let h265: UInt32 = 0x6832_3635
    public static let av1: UInt32 = 0x0061_7631
}

public enum ScrcpyDemuxerEvent: Sendable, Hashable {
    case deviceName(String)
    case codec(UInt32)
    /// Starts every capture session, including the first. A rotation or fold restarts the
    /// session, so a later one carries the new dimensions; a config packet and key frame follow.
    case session(width: Int, height: Int)
    case config(Data)
    case frame(Data, pts: UInt64, isKeyFrame: Bool)
}

public enum ScrcpyDemuxerError: Error, Equatable, CustomStringConvertible {
    case streamDisabled
    case serverConfigurationError
    case invalidSession(width: Int, height: Int)
    case packetTooLarge(Int)

    public var description: String {
        switch self {
        case .streamDisabled: "The device disabled the video stream."
        case .serverConfigurationError: "scrcpy-server reported a configuration error; see its log."
        case let .invalidSession(width, height): "scrcpy-server sent an invalid video size \(width)x\(height)."
        case let .packetTooLarge(size): "scrcpy-server sent a \(size)-byte packet, larger than any plausible frame."
        }
    }
}

/// Parses the video socket of scrcpy 5.0.1 (`app/src/demuxer.c`, `server/.../device/Streamer.java`):
/// a 64-byte device name, a u32 codec id, then 12-byte headers. A header whose top bit is set is a
/// session packet (flags u32, width u32, height u32); otherwise it is a media packet
/// (pts-and-flags u64, size u32) followed by its payload.
public struct ScrcpyDemuxer: Sendable {
    static let deviceNameLength = 64
    static let headerLength = 12
    static let sessionFlag: UInt64 = 1 << 63
    static let configFlag: UInt64 = 1 << 62
    static let keyFrameFlag: UInt64 = 1 << 61
    static let ptsMask: UInt64 = keyFrameFlag - 1
    static let maxPacketSize = 64 * 1024 * 1024

    private enum State {
        case deviceName
        case codec
        case header
        case payload(ptsAndFlags: UInt64, size: Int)
    }

    private var state: State
    private var buffer = Data()

    public init(expectsDeviceName: Bool = true) {
        state = expectsDeviceName ? .deviceName : .codec
    }

    public mutating func feed(_ bytes: Data) throws -> [ScrcpyDemuxerEvent] {
        buffer.append(bytes)
        var events: [ScrcpyDemuxerEvent] = []
        while let event = try next() {
            events.append(event)
        }
        if buffer.startIndex != 0 {
            buffer = Data(buffer)
        }
        return events
    }

    private mutating func next() throws -> ScrcpyDemuxerEvent? {
        switch state {
        case .deviceName:
            guard let raw = take(Self.deviceNameLength) else { return nil }
            state = .codec
            let name = raw.prefix { $0 != 0 }
            return .deviceName(String(decoding: name, as: UTF8.self))

        case .codec:
            guard let raw = take(4) else { return nil }
            let codec = raw.readU32(at: 0)
            switch codec {
            case 0: throw ScrcpyDemuxerError.streamDisabled
            case 1: throw ScrcpyDemuxerError.serverConfigurationError
            default: break
            }
            state = .header
            return .codec(codec)

        case .header:
            guard let raw = take(Self.headerLength) else { return nil }
            let ptsAndFlags = raw.readU64(at: 0)
            if ptsAndFlags & Self.sessionFlag != 0 {
                let width = Int(raw.readU32(at: 4))
                let height = Int(raw.readU32(at: 8))
                guard width > 0, height > 0, width <= 0xFFFF, height <= 0xFFFF else {
                    throw ScrcpyDemuxerError.invalidSession(width: width, height: height)
                }
                return .session(width: width, height: height)
            }
            let size = Int(raw.readU32(at: 8))
            guard size <= Self.maxPacketSize else { throw ScrcpyDemuxerError.packetTooLarge(size) }
            state = .payload(ptsAndFlags: ptsAndFlags, size: size)
            return try next()

        case let .payload(ptsAndFlags, size):
            guard let payload = take(size) else { return nil }
            state = .header
            if ptsAndFlags & Self.configFlag != 0 {
                return .config(payload)
            }
            return .frame(payload, pts: ptsAndFlags & Self.ptsMask, isKeyFrame: ptsAndFlags & Self.keyFrameFlag != 0)
        }
    }

    private mutating func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        let start = buffer.startIndex
        let chunk = Data(buffer[start..<start + count])
        buffer = buffer[(start + count)...]
        return chunk
    }
}

extension Data {
    func readU16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) << 8 | UInt16(self[base + 1])
    }

    func readU32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(self[base + index]) }
        return value
    }

    func readU64(at offset: Int) -> UInt64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(self[base + index]) }
        return value
    }
}
