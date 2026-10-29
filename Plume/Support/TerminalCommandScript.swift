import AppKit

/// Runs a command in Terminal.app through a temporary `.command` script that deletes itself.
enum TerminalCommandScript {
    private static let terminalBundleID = "com.apple.Terminal"

    static func script(command: String) -> String {
        """
        #!/bin/sh
        rm -f "$0"
        \(command)

        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `onFailure` gets a message to show when the script couldn't be written or Terminal couldn't open it.
    static func open(prefix: String, command: String, onFailure: @escaping @MainActor (String) -> Void) {
        do {
            let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).command")
            try script(command: command).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
                onFailure("Terminal.app wasn't found.")
                return
            }
            NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in onFailure(message) }
            }
        } catch {
            onFailure(error.localizedDescription)
        }
    }
}
