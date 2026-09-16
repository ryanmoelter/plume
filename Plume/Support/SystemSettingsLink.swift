import AppKit
import Foundation

/// A pane of System Settings that Plume can send the user to, for the settings
/// it can explain but not change itself.
enum SystemSettingsLink {
    case battery

    /// Falls back to opening System Settings at whatever pane it last showed:
    /// the extension identifiers are private, so an OS release renaming one
    /// should still land the user somewhere useful.
    private var url: URL? {
        switch self {
        case .battery:
            URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        }
    }

    func open() {
        guard let url, NSWorkspace.shared.open(url) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }
    }
}
