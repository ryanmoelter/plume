import Foundation
import os

/// Finds `claude` processes that were launched the way Plume launches them.
///
/// Matched on the `--settings` path, which is Plume's own and distinguishes
/// its agents from a `claude` the user is running in a terminal, and from the
/// Claude desktop app's helper processes. Ownership is decided by the caller:
/// this only reports what is running.
enum ClaudeProcessScanner {
    /// Pids of every `claude` process carrying Plume's settings path.
    ///
    /// Best-effort. A failure to scan reports nothing running rather than
    /// blocking a resume, since the cost of a missed orphan is a forked
    /// transcript while the cost of a false positive is a tab that will not
    /// start at all.
    static func plumeLaunchedProcessIDs(
        settingsPath: String = AppPaths.hookSettingsFile.path
    ) -> Set<pid_t> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,command="]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.agent.error("Could not scan for agent processes: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return parse(psOutput: String(decoding: data, as: UTF8.self), settingsPath: settingsPath)
    }

    /// Split out so the match survives without spawning `ps`.
    static func parse(psOutput: String, settingsPath: String) -> Set<pid_t> {
        var pids: Set<pid_t> = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let separator = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(trimmed[trimmed.startIndex..<separator]) else { continue }
            let command = trimmed[separator...]
            guard command.contains(settingsPath) else { continue }
            // The login shell that spawned the agent carries the same
            // settings path on its own command line, and dies with it.
            guard command.contains("claude") else { continue }
            pids.insert(pid)
        }
        return pids
    }
}
