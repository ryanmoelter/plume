import Darwin
import Foundation
import SwiftUI

@main
enum PlumeMain {
    static func main() {
        if let name = CommandLine.arguments.first, ToolHandoff.handsOff(argv0: name) {
            ToolHandoff.execTool()
        }
        PlumeApp.main()
    }
}

/// A shell on a case-insensitive volume finds `Contents/MacOS/Plume` for
/// `plume` whenever that folder is on PATH, and would start a second GUI app
/// that never exits. Run under a name the bundled tool answers to, the app
/// becomes the tool instead.
nonisolated enum ToolHandoff {
    static func handsOff(argv0: String) -> Bool {
        let name = (argv0 as NSString).lastPathComponent
        return name == "plume" || name == CLICommandLine.notifyAlias || name == CLICommandLine.wtAlias
    }

    static func toolPath(executablePath: String) -> String {
        URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Helpers/plume")
            .path
    }

    static func execTool() -> Never {
        let tool = toolPath(executablePath: resolvedExecutablePath() ?? "")
        execv(tool, CommandLine.unsafeArgv)
        let reason = String(cString: strerror(errno))
        FileHandle.standardError.write(Data("plume: could not run \(tool): \(reason)\n".utf8))
        exit(CLIExitCode.failure)
    }

    /// Launched through a symlink, the executable path names the link, not the
    /// bundle.
    private static func resolvedExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        guard let resolved = realpath(buffer, nil) else { return String(cString: buffer) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
