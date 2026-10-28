import Foundation

nonisolated struct AndroidSDK: Sendable, Equatable {
    let root: URL
    /// Nil for an adb-only install, such as Homebrew's platform-tools.
    let emulatorURL: URL?
    let adbURL: URL?
    /// `ANDROID_*` from the login shell, plus `ANDROID_HOME` pointing at `root`.
    let launchEnvironment: [String: String]
}

nonisolated enum AndroidSDKLookup: Sendable, Equatable {
    case found(AndroidSDK)
    case notFound(searchedPaths: [String])

    var sdk: AndroidSDK? {
        if case .found(let sdk) = self { return sdk }
        return nil
    }
}

nonisolated enum AndroidSDKLocator {
    static let beginMarker = "__PLUME_ANDROID_BEGIN__"
    static let endMarker = "__PLUME_ANDROID_END__"

    private static let cache = Cache()

    /// Computed once per process; a login shell with rc files is too slow to repeat.
    static func locate(refresh: Bool = false) async -> AndroidSDKLookup {
        if !refresh, let cached = cache.value { return cached }
        let result = await Task.detached(priority: .userInitiated) { discover() }.value
        cache.value = result
        return result
    }

    static func invalidate() { cache.value = nil }

    /// `root` is the first candidate whose `emulator/emulator` is executable, else the first with
    /// `platform-tools/adb`. `adbRoot` is `root` when it has adb, else the first candidate that does,
    /// so an emulator-only SDK still pairs with an adb found elsewhere. Expands `~`, drops duplicates.
    static func resolve(
        candidates: [String],
        isExecutable: (String) -> Bool,
        home: String = NSHomeDirectory()
    ) -> (root: String?, adbRoot: String?, searched: [String]) {
        var searched: [String] = []
        var emulatorRoot: String?
        var firstADBRoot: String?
        for candidate in candidates {
            let expanded = expandTilde(candidate, home: home)
            guard !expanded.isEmpty, !searched.contains(expanded) else { continue }
            searched.append(expanded)
            let hasADB = isExecutable(expanded + "/platform-tools/adb")
            if emulatorRoot == nil, isExecutable(expanded + "/emulator/emulator") {
                if hasADB { return (expanded, expanded, searched) }
                emulatorRoot = expanded
            }
            if firstADBRoot == nil, hasADB { firstADBRoot = expanded }
            if emulatorRoot != nil, firstADBRoot != nil { break }
        }
        return (emulatorRoot ?? firstADBRoot, firstADBRoot, searched)
    }

    static func expandTilde(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + String(trimmed.dropFirst(1)) }
        return trimmed
    }

    /// Parses `KEY=value` lines between the sentinel markers; rc-file noise outside them is ignored.
    static func parseShellOutput(_ output: String) -> (environment: [String: String], adbPath: String?) {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex)
        else { return ([:], nil) }
        var environment: [String: String] = [:]
        var adbPath: String?
        for rawLine in output[begin.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if key == "PLUME_ADB" {
                if !value.isEmpty { adbPath = value }
            } else if key.hasPrefix("ANDROID_"), !value.isEmpty {
                environment[key] = value
            }
        }
        return (environment, adbPath)
    }

    /// `<root>/platform-tools/adb` -> `<root>`, after symlink resolution.
    static func sdkRoot(fromADB adbPath: String, resolveSymlinks: (String) -> String) -> String? {
        let resolved = resolveSymlinks(adbPath)
        let suffix = "/platform-tools/adb"
        guard resolved.hasSuffix(suffix) else { return nil }
        return String(resolved.dropLast(suffix.count))
    }

    private static func discover() -> AndroidSDKLookup {
        let processEnv = ProcessInfo.processInfo.environment
        let shell = queryLoginShell()
        let manager = FileManager.default
        let isExecutable: (String) -> Bool = { manager.isExecutableFile(atPath: $0) }
        let home = NSHomeDirectory()

        var candidates = [processEnv["ANDROID_HOME"], processEnv["ANDROID_SDK_ROOT"],
                          shell.environment["ANDROID_HOME"], shell.environment["ANDROID_SDK_ROOT"],
                          home + "/Library/Android/sdk", home + "/.android/sdk"].compactMap { $0 }
        if let adb = shell.adbPath,
           let root = sdkRoot(fromADB: adb, resolveSymlinks: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) {
            candidates.append(root)
        }

        let (root, adbRoot, searched) = resolve(candidates: candidates, isExecutable: isExecutable, home: home)
        guard let root else { return .notFound(searchedPaths: searched) }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let emulator = rootURL.appending(path: "emulator/emulator")
        let adb = adbRoot.map { URL(fileURLWithPath: $0, isDirectory: true).appending(path: "platform-tools/adb") }
        var environment = shell.environment
        environment["ANDROID_HOME"] = root
        return .found(AndroidSDK(
            root: rootURL,
            emulatorURL: isExecutable(emulator.path) ? emulator : nil,
            adbURL: adb,
            launchEnvironment: environment
        ))
    }

    static let loginShellTimeout: TimeInterval = 5

    private static func queryLoginShell() -> (environment: [String: String], adbPath: String?) {
        let script = "echo \(beginMarker); env | grep '^ANDROID_'; echo PLUME_ADB=$(command -v adb); echo \(endMarker)"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let output = runCapturingOutput(executable: shell, arguments: ["-lic", script], timeout: loginShellTimeout) else {
            return ([:], nil)
        }
        return parseShellOutput(output)
    }

    /// Runs in its own process group so a timeout kills helpers the shell backgrounded too, since they can hold the pipe open.
    /// Returns nil on a spawn failure or timeout.
    static func runCapturingOutput(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return nil }
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            return nil
        }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, 1000)) + 1)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let count = read(readEnd, &chunk, chunk.count)
            if count > 0 { data.append(contentsOf: chunk.prefix(count)) }
            else if count == 0 || errno != EINTR { break }
        }
        close(readEnd)
        if timedOut { kill(-pid, SIGKILL) }
        var exitStatus: Int32 = 0
        while waitpid(pid, &exitStatus, 0) == -1, errno == EINTR {}
        return timedOut ? nil : String(decoding: data, as: UTF8.self)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AndroidSDKLookup?
        var value: AndroidSDKLookup? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
