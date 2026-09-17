import AppKit

enum ExternalDisplay {
    /// True when any attached screen is not the built-in panel, which is what
    /// makes a shut lid clamshell mode rather than a Mac put away.
    static var isConnected: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
    }
}
