/// Android input constants, from the NDK's `android/input.h` and `android/keycodes.h`.
public enum Android {
    public enum KeyAction {
        public static let down: UInt8 = 0
        public static let up: UInt8 = 1
    }

    public enum MotionAction {
        public static let down: UInt8 = 0
        public static let up: UInt8 = 1
        public static let move: UInt8 = 2
        public static let cancel: UInt8 = 3
        public static let pointerDown: UInt8 = 5
        public static let pointerUp: UInt8 = 6
        public static let hoverMove: UInt8 = 7
        public static let hoverEnter: UInt8 = 9
        public static let hoverExit: UInt8 = 10
    }

    public enum MotionButton {
        public static let primary: UInt32 = 1 << 0
        public static let secondary: UInt32 = 1 << 1
        public static let tertiary: UInt32 = 1 << 2
        public static let back: UInt32 = 1 << 3
        public static let forward: UInt32 = 1 << 4
    }

    public enum Meta {
        public static let none: UInt32 = 0
        public static let altOn: UInt32 = 0x02
        public static let altLeftOn: UInt32 = 0x10
        public static let altRightOn: UInt32 = 0x20
        public static let shiftOn: UInt32 = 0x01
        public static let shiftLeftOn: UInt32 = 0x40
        public static let shiftRightOn: UInt32 = 0x80
        public static let symOn: UInt32 = 0x04
        public static let functionOn: UInt32 = 0x08
        public static let ctrlOn: UInt32 = 0x1000
        public static let ctrlLeftOn: UInt32 = 0x2000
        public static let ctrlRightOn: UInt32 = 0x4000
        public static let metaOn: UInt32 = 0x10000
        public static let metaLeftOn: UInt32 = 0x20000
        public static let metaRightOn: UInt32 = 0x40000
        public static let capsLockOn: UInt32 = 0x100000
        public static let numLockOn: UInt32 = 0x200000
        public static let scrollLockOn: UInt32 = 0x400000
    }

    public enum KeyCode {
        public static let home: UInt32 = 3
        public static let back: UInt32 = 4
        public static let dpadUp: UInt32 = 19
        public static let dpadDown: UInt32 = 20
        public static let dpadLeft: UInt32 = 21
        public static let dpadRight: UInt32 = 22
        public static let dpadCenter: UInt32 = 23
        public static let volumeUp: UInt32 = 24
        public static let volumeDown: UInt32 = 25
        public static let power: UInt32 = 26
        public static let tab: UInt32 = 61
        public static let space: UInt32 = 62
        public static let enter: UInt32 = 66
        public static let del: UInt32 = 67
        public static let menu: UInt32 = 82
        public static let pageUp: UInt32 = 92
        public static let pageDown: UInt32 = 93
        public static let escape: UInt32 = 111
        public static let forwardDel: UInt32 = 112
        public static let moveHome: UInt32 = 122
        public static let moveEnd: UInt32 = 123
        public static let volumeMute: UInt32 = 164
        public static let appSwitch: UInt32 = 187
        public static let wakeup: UInt32 = 224
    }
}
