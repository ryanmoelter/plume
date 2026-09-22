import Foundation

/// Whether Plume holds Full Disk Access, and where to send the user to grant
/// it.
///
/// macOS exposes no API that reports or requests this permission. The only
/// reliable probe is to read a file the TCC database protects and see whether
/// it is denied, and the only way to grant it is System Settings — so
/// everything here is a check plus a deep link, never a request.
enum FullDiskAccess {
    /// A path readable only with Full Disk Access, and readable by every user
    /// that has it. TCC's own database is the conventional probe: it always
    /// exists, and nothing but Full Disk Access opens it.
    private static var probePath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// Whether the probe file opens. False also covers the case where the file
    /// is missing, which is why this only ever gates an explanation and never
    /// blocks anything.
    static var isGranted: Bool {
        guard let handle = try? FileHandle(forReadingFrom: probePath) else { return false }
        try? handle.close()
        return true
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}
