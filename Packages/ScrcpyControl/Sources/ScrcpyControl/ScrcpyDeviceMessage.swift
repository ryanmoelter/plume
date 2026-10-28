import Foundation

/// Device-to-client messages on the control socket (`server/.../control/DeviceMessageWriter.java`).
public enum ScrcpyDeviceMessage: Sendable, Hashable {
    case clipboard(String)
    case ackClipboard(sequence: UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

/// Parses device messages incrementally. After an unknown type it can no longer find message
/// boundaries, so it discards everything that follows; the socket still drains.
struct ScrcpyDeviceMessageParser {
    private var buffer = Data()
    private(set) var lostSync = false

    mutating func feed(_ bytes: Data) -> [ScrcpyDeviceMessage] {
        guard !lostSync else { return [] }
        buffer.append(bytes)
        var messages: [ScrcpyDeviceMessage] = []
        while let (message, length) = parseOne() {
            buffer.removeFirst(length)
            if let message { messages.append(message) }
        }
        return messages
    }

    /// Returns nil when more bytes are needed; a nil message consumes bytes without yielding one.
    private mutating func parseOne() -> (ScrcpyDeviceMessage?, Int)? {
        let bytes = Data(buffer)
        guard let type = bytes.first else { return nil }
        switch type {
        case 0:
            guard bytes.count >= 5 else { return nil }
            let length = Int(bytes.readU32(at: 1))
            guard bytes.count >= 5 + length else { return nil }
            let text = String(decoding: bytes[5..<5 + length], as: UTF8.self)
            return (.clipboard(text), 5 + length)
        case 1:
            guard bytes.count >= 9 else { return nil }
            return (.ackClipboard(sequence: bytes.readU64(at: 1)), 9)
        case 2:
            guard bytes.count >= 5 else { return nil }
            let id = bytes.readU16(at: 1)
            let length = Int(bytes.readU16(at: 3))
            guard bytes.count >= 5 + length else { return nil }
            return (.uhidOutput(id: id, data: Data(bytes[5..<5 + length])), 5 + length)
        default:
            lostSync = true
            return (nil, bytes.count)
        }
    }
}
