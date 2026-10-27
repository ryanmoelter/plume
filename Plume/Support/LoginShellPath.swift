import Foundation

/// The PATH the user's terminals see. A GUI-launched app inherits only the
/// launchd PATH, so tools the user's shell profile puts on it are invisible.
nonisolated enum LoginShellPath {
    static let marker = "__PLUME_PATH__"

    /// The directories of the PATH `shell` reports as a login, interactive
    /// shell, the way Plume's terminal tabs start. Blocks on a process, so
    /// call it off the main actor. Falls back to `fallback` when the shell
    /// fails, times out or prints no PATH.
    static func directories(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 5,
        fallback: [String] = fallbackDirectories()
    ) -> [String] {
        let resolvedShell = shell?.isEmpty == false ? shell! : "/bin/zsh"
        guard let output = run(shell: resolvedShell, timeout: timeout),
              let path = parse(output)
        else { return fallback }
        return path.split(separator: ":").map(String.init)
    }

    /// The PATH after the last marker, which skips anything a profile printed.
    static func parse(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else { return nil }
        let path = line.dropFirst(marker.count)
        return path.isEmpty ? nil : String(path)
    }

    /// This process's PATH plus `~/.local/bin`, where Plume links its tool.
    static func fallbackDirectories() -> [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let local = URL.homeDirectory.appending(path: ".local/bin").path
        return inherited.contains(local) ? inherited : inherited + [local]
    }

    private static func run(shell: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        let box = OutputBox()
        let reading = DispatchGroup()
        reading.enter()
        Thread {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }.start()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        reading.wait()
        return process.terminationStatus == 0 ? String(decoding: box.data, as: UTF8.self) : nil
    }
}

/// Written once by the reader thread, read after `DispatchGroup.wait`.
private nonisolated final class OutputBox: @unchecked Sendable {
    var data = Data()
}
