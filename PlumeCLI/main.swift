import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment
let executableName = CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "plume"

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func run(_ invocation: CLIInvocation) -> Int32 {
    switch invocation {
    case .help:
        print(CLICommandLine.usage)
    case .notifyHelp:
        print(CLICommandLine.notifyUsage)
    case .version:
        print("plume \(BundleVersion.current() ?? "(not inside Plume.app)")")
    case .notify(let title, let body):
        Notify.send(title: title, body: body)
    case .presence(let json):
        let report = Presence.current()
        if json {
            guard let line = try? CLILineCodec.encode(report) else { return CLIExitCode.failure }
            FileHandle.standardOutput.write(line)
        } else {
            print(report.state.rawValue)
        }
    case .newTab(let directory, let taskID, let select):
        return NewTab.run(directory: directory, taskID: taskID, select: select)
    case .shellInit:
        print(ShellIntegration.zsh(), terminator: "")
    }
    return CLIExitCode.success
}

enum Notify {
    /// Never fails its caller, which is often a hook: inside a Plume tab the
    /// app routes it, otherwise the terminal gets an OSC 777, and with no
    /// terminal at all it does nothing.
    static func send(title: String, body: String) {
        if let tabID = environment[CLISocket.tabIDEnvironmentKey].flatMap(UUID.init(uuidString:)) {
            let request = CLIRequest.notify(.init(tabID: tabID, title: title, body: body))
            let response = try? CLISocket.send(request, to: CLISocket.resolvedPath(environment: environment), timeout: 2)
            if response?.ok == true { return }
        }
        writeToTerminal(CLICommandLine.osc777(title: title, body: body))
    }

    /// The escape has to reach the terminal, not stdout: called inside
    /// `$(...)` or with stdout redirected, stdout would notify nothing. With
    /// no controlling terminal the open fails, and that is the silent case.
    private static func writeToTerminal(_ payload: String) {
        let fd = open("/dev/tty", O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        try? CLISocket.writeAll(Data(payload.utf8), to: fd)
    }
}

enum NewTab {
    static func run(directory: String?, taskID: String?, select: Bool) -> Int32 {
        var target = CLIRequest.NewTab(select: select)
        if let taskID {
            guard let taskUUID = UUID(uuidString: taskID) else {
                printError("plume: '\(taskID)' is not a task ID")
                return CLIExitCode.usage
            }
            target.taskID = taskUUID
        } else if let tabID = environment[CLISocket.tabIDEnvironmentKey].flatMap(UUID.init(uuidString:)) {
            // The tab rather than the task, since a moved tab keeps its ID
            // but not its task.
            target.tabID = tabID
        } else if let taskUUID = environment[CLISocket.taskIDEnvironmentKey].flatMap(UUID.init(uuidString:)) {
            target.taskID = taskUUID
        } else {
            printError("plume: not inside a Plume task; pass --task ID")
            return CLIExitCode.failure
        }
        if let directory {
            let path = absolutePath(directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                printError("plume: no such directory: \(directory)")
                return CLIExitCode.failure
            }
            target.directory = path
        }

        let request = CLIRequest.newTab(target)
        do {
            let response = try CLISocket.send(request, to: CLISocket.resolvedPath(environment: environment))
            guard response.ok, let tabID = response.tabID else {
                printError("plume: \(response.error ?? "Plume could not open the tab")")
                return CLIExitCode.failure
            }
            print(tabID.uuidString)
            return CLIExitCode.success
        } catch CLISocket.ClientError.unreachable {
            printError("plume: Plume isn't running")
            return CLIExitCode.failure
        } catch {
            printError("plume: \(error.localizedDescription)")
            return CLIExitCode.failure
        }
    }

    private static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
    }
}

enum BundleVersion {
    /// Read from the enclosing app's Info.plist, so the tool needs no
    /// version of its own. Follows the `~/.local/bin` symlink to find it.
    static func current() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard
            let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
            let version = info["CFBundleShortVersionString"] as? String
        else { return nil }
        if let build = info["CFBundleVersion"] as? String { return "\(version) (\(build))" }
        return version
    }
}

do {
    let invocation = try CLICommandLine.parse(Array(CommandLine.arguments.dropFirst()), executableName: executableName)
    exit(run(invocation))
} catch let error as CLIUsageError {
    printError("plume: \(error.message)")
    printError(error.usage)
    exit(CLIExitCode.usage)
} catch {
    printError("plume: \(error.localizedDescription)")
    exit(CLIExitCode.failure)
}
