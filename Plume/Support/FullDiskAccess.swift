import Foundation

/// Whether Plume holds Full Disk Access, and where to send the user to grant
/// it.
///
/// macOS exposes no API that reports or requests this permission. The only
/// reliable probe is to read a file the TCC database protects and see whether
/// it is denied, and the only way to grant it is System Settings — so
/// everything here is a check plus a deep link, never a request.
enum FullDiskAccess {
    /// Paths readable only with Full Disk Access. TCC's own databases are the
    /// conventional probe. The system one comes first because it always
    /// exists, while a user may have no `TCC.db` of their own, as in a fresh
    /// macOS 27 VM guest.
    private static var probePaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
        ]
    }

    /// Whether any probe file opens. False also covers missing files, which
    /// is why this only ever gates an explanation and never blocks anything.
    static var isGranted: Bool {
        probePaths.contains { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            try? handle.close()
            return true
        }
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access.
    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}
