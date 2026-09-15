import Foundation

/// Whether `claude` is reachable from the login shell the agent transports
/// actually launch through.
///
/// A GUI-launched app inherits none of the user's shell PATH, so asking
/// `ProcessInfo` or probing the app's own PATH answers a different question
/// than the one that matters. The probe runs the same `$SHELL -lic` wrapper
/// `LoginShellCommand` builds for the real launch.
nonisolated enum ClaudeCLILocator {
    /// Cached because this is read on the launch path and each miss costs a
    /// full login shell — profile sourcing included. A user who installs the
    /// CLI mid-session gets a correct answer after `invalidate()`, which the
    /// failure UI's retry calls.
    private static let cache = Cache()

    static func isAvailable(commandName: String = "claude") -> Bool {
        if let cached = cache.value { return cached }
        let found = probe(commandName: commandName)
        cache.value = found
        return found
    }

    static func invalidate() {
        cache.value = nil
    }

    /// `command -v` rather than `which`: it is a shell builtin, so it answers
    /// for aliases and functions too, and needs no binary on the bare PATH
    /// the probe starts from.
    private static func probe(commandName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", LoginShellCommand.wrap("command -v \(commandName)")]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // The probe itself failing says nothing about the CLI, so assume
            // it is present and let the real launch report what happens.
            return true
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?

        var value: Bool? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
