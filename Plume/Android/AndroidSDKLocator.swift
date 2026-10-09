import Foundation

nonisolated struct AndroidSDK: Sendable, Equatable {
    let root: URL
    let emulatorURL: URL
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

    /// First candidate whose `emulator/emulator` is executable. Expands `~`, drops duplicates.
    static func resolve(
        candidates: [String],
        isExecutable: (String) -> Bool,
        home: String = NSHomeDirectory()
    ) -> (root: String?, searched: [String]) {
        var searched: [String] = []
        for candidate in candidates {
            let expanded = expandTilde(candidate, home: home)
            guard !expanded.isEmpty, !searched.contains(expanded) else { continue }
            searched.append(expanded)
            if isExecutable(expanded + "/emulator/emulator") { return (expanded, searched) }
        }
        return (nil, searched)
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

        let (root, searched) = resolve(candidates: candidates, isExecutable: isExecutable, home: home)
        guard let root else { return .notFound(searchedPaths: searched) }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let adb = rootURL.appending(path: "platform-tools/adb")
        var environment = shell.environment
        environment["ANDROID_HOME"] = root
        return .found(AndroidSDK(
            root: rootURL,
            emulatorURL: rootURL.appending(path: "emulator/emulator"),
            adbURL: isExecutable(adb.path) ? adb : nil,
            launchEnvironment: environment
        ))
    }

    private static func queryLoginShell() -> (environment: [String: String], adbPath: String?) {
        let script = "echo \(beginMarker); env | grep '^ANDROID_'; echo PLUME_ADB=$(command -v adb); echo \(endMarker)"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ([:], nil) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseShellOutput(String(decoding: data, as: UTF8.self))
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
