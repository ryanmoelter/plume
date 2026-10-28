import CoreGraphics

public struct EmulatorEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var token: String?

    public init(host: String = "127.0.0.1", port: Int, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
    }
}

public enum EmulatorRotation: Sendable, Hashable {
    case portrait
    case landscape
    case reversePortrait
    case reverseLandscape
}

public struct EmulatorFrame: @unchecked Sendable {
    public let image: CGImage
    public let pixelSize: CGSize
    public let rotation: EmulatorRotation
    public let seq: UInt32

    public init(image: CGImage, pixelSize: CGSize, rotation: EmulatorRotation, seq: UInt32) {
        self.image = image
        self.pixelSize = pixelSize
        self.rotation = rotation
        self.seq = seq
    }
}

public struct TouchPoint: Sendable, Hashable {
    public var x: Int32
    public var y: Int32
    public var identifier: Int32
    /// Zero lifts the contact.
    public var pressure: Int32

    public init(x: Int32, y: Int32, identifier: Int32, pressure: Int32) {
        self.x = x
        self.y = y
        self.identifier = identifier
        self.pressure = pressure
    }
}

public enum KeyPhase: Sendable, Hashable {
    case down
    case up
    case press
}

public enum KeyInput: Sendable, Hashable {
    case mac(keyCode: Int32, phase: KeyPhase)
    /// Needed for keys whose Mac code is 0, which the emulator drops.
    case evdev(keyCode: Int32, phase: KeyPhase)
    /// A W3C `KeyboardEvent.key` value such as "Enter" or "Backspace".
    case named(String, phase: KeyPhase)
    case text(String)
}

public enum HardwareButton: String, Sendable, Hashable {
    case back = "GoBack"
    case home = "GoHome"
    case overview = "AppSwitch"
    case power = "Power"
    case volumeUp = "AudioVolumeUp"
    case volumeDown = "AudioVolumeDown"
}

public enum EmulatorInput: Sendable, Hashable {
    case touch([TouchPoint])
    /// Moves the guest's pointer. A wheel event has no position of its own and scrolls under the pointer.
    case mouse(x: Int32, y: Int32, buttons: Int32)
    case wheel(dx: Int32, dy: Int32)
    case key(KeyInput)
}

public struct EmulatorStatusSnapshot: Sendable {
    public var booted: Bool
    public var version: String
    public var displaySize: CGSize?

    public init(booted: Bool, version: String, displaySize: CGSize?) {
        self.booted = booted
        self.version = version
        self.displaySize = displaySize
    }
}

extension HardwareButton {
    /// The emulator ignores the named volume keys, so they go out as evdev codes.
    var evdevKeyCode: Int32? {
        switch self {
        case .volumeUp: 115
        case .volumeDown: 114
        default: nil
        }
    }
}
