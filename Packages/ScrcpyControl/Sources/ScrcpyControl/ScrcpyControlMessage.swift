import CoreGraphics
import Foundation

/// A pixel position in the video frame, with the frame size it was measured against.
/// The server drops any event whose `screenSize` differs from its current video size,
/// so after a rotation stale events vanish instead of landing in the wrong place.
public struct ScrcpyPosition: Sendable, Hashable {
    public var x: Int32
    public var y: Int32
    public var screenWidth: UInt16
    public var screenHeight: UInt16

    public init(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16) {
        self.x = x
        self.y = y
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    public init(point: CGPoint, screenSize: CGSize) {
        self.init(
            x: Int32(point.x.rounded()),
            y: Int32(point.y.rounded()),
            screenWidth: UInt16(clamping: Int(screenSize.width)),
            screenHeight: UInt16(clamping: Int(screenSize.height))
        )
    }
}

public enum ScrcpyPointerID {
    public static let mouse: UInt64 = .max
    public static let genericFinger: UInt64 = .max - 1
    public static let virtualFinger: UInt64 = .max - 2
}

/// Client-to-device messages, encoded exactly as scrcpy's `app/src/control_msg.c`.
public enum ScrcpyControlMessage: Sendable, Hashable {
    case injectKeycode(action: UInt8, keycode: UInt32, repeat: UInt32 = 0, metaState: UInt32 = Android.Meta.none)
    /// Longer text is truncated at a character boundary to the server's 300-byte limit.
    case injectText(String)
    /// `pressure` is 0...1.
    case injectTouch(action: UInt8, pointerID: UInt64, position: ScrcpyPosition, pressure: Float, actionButton: UInt32, buttons: UInt32)
    /// Scroll amounts are clamped to -16...16.
    case injectScroll(position: ScrcpyPosition, hScroll: Float, vScroll: Float, buttons: UInt32)
    /// Back when the screen is on, power on when it is off.
    case backOrScreenOn(action: UInt8)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case setDisplayPower(on: Bool)
    case rotateDevice
    /// Restarts the encoder, so the next packets are a fresh session, config and key frame.
    case resetVideo

    public static let injectTextMaxLength = 300

    enum TypeCode: UInt8 {
        case injectKeycode = 0
        case injectText = 1
        case injectTouchEvent = 2
        case injectScrollEvent = 3
        case backOrScreenOn = 4
        case expandNotificationPanel = 5
        case expandSettingsPanel = 6
        case collapsePanels = 7
        case setDisplayPower = 10
        case rotateDevice = 11
        case resetVideo = 17
    }

    public func encoded() -> Data {
        var out = ByteWriter()
        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            out.u8(TypeCode.injectKeycode.rawValue)
            out.u8(action)
            out.u32(keycode)
            out.u32(repeatCount)
            out.u32(metaState)
        case let .injectText(text):
            let bytes = Self.utf8Truncated(text, maxBytes: Self.injectTextMaxLength)
            out.u8(TypeCode.injectText.rawValue)
            out.u32(UInt32(bytes.count))
            out.bytes(bytes)
        case let .injectTouch(action, pointerID, position, pressure, actionButton, buttons):
            out.u8(TypeCode.injectTouchEvent.rawValue)
            out.u8(action)
            out.u64(pointerID)
            out.position(position)
            out.u16(Self.u16FixedPoint(pressure))
            out.u32(actionButton)
            out.u32(buttons)
        case let .injectScroll(position, hScroll, vScroll, buttons):
            out.u8(TypeCode.injectScrollEvent.rawValue)
            out.position(position)
            out.u16(UInt16(bitPattern: Self.i16FixedPoint(hScroll / 16)))
            out.u16(UInt16(bitPattern: Self.i16FixedPoint(vScroll / 16)))
            out.u32(buttons)
        case let .backOrScreenOn(action):
            out.u8(TypeCode.backOrScreenOn.rawValue)
            out.u8(action)
        case .expandNotificationPanel:
            out.u8(TypeCode.expandNotificationPanel.rawValue)
        case .expandSettingsPanel:
            out.u8(TypeCode.expandSettingsPanel.rawValue)
        case .collapsePanels:
            out.u8(TypeCode.collapsePanels.rawValue)
        case let .setDisplayPower(on):
            out.u8(TypeCode.setDisplayPower.rawValue)
            out.u8(on ? 1 : 0)
        case .rotateDevice:
            out.u8(TypeCode.rotateDevice.rawValue)
        case .resetVideo:
            out.u8(TypeCode.resetVideo.rawValue)
        }
        return out.data
    }

    /// `sc_float_to_u16fp`: 1.0 saturates to 0xffff.
    static func u16FixedPoint(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        let scaled = UInt32(clamped * 65536)
        return UInt16(min(scaled, 0xffff))
    }

    /// `sc_float_to_i16fp`: 1.0 saturates to 0x7fff, -1.0 is exactly -0x8000.
    static func i16FixedPoint(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        let scaled = Int32(clamped * 32768)
        return Int16(min(scaled, 0x7fff))
    }

    static func utf8Truncated(_ text: String, maxBytes: Int) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return bytes }
        var end = maxBytes
        // Back off any continuation bytes (10xxxxxx) so the cut lands on a character start.
        while end > 0, bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }
        return Array(bytes[..<end])
    }
}

struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }

    mutating func position(_ position: ScrcpyPosition) {
        u32(UInt32(bitPattern: position.x))
        u32(UInt32(bitPattern: position.y))
        u16(position.screenWidth)
        u16(position.screenHeight)
    }
}
