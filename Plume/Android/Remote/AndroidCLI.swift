import Foundation

nonisolated struct AndroidCLIResult: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false

    var succeeded: Bool { status == 0 && !timedOut }

    /// Everything the command printed, for matching messages that may land on either stream.
    var output: String { stdout + "\n" + stderr }

    /// What to show the user when the command failed.
    var failureMessage: String {
        if timedOut { return "The android command did not finish in time." }
        let text = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return text ?? "The android command failed with status \(status)."
    }
}

nonisolated struct AndroidCLIError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static let notInstalled = AndroidCLIError(message: "The android command-line tool wasn't found.")
}

/// Runs the `android` command-line tool. Behind a protocol so tests never reach Google.
nonisolated protocol AndroidCLIRunning: Sendable {
    /// Throws only when the tool can't be found or spawned. `onOutput` gets each new piece of stdout as it arrives.
    func run(
        _ arguments: [String],
        timeout: Duration,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> AndroidCLIResult
}

nonisolated extension AndroidCLIRunning {
    func run(_ arguments: [String], timeout: Duration = AndroidCLI.defaultTimeout) async throws -> AndroidCLIResult {
        try await run(arguments, timeout: timeout, onOutput: nil)
    }
}

nonisolated final class AndroidCLI: AndroidCLIRunning, @unchecked Sendable {
    static let shared = AndroidCLI()
    static let defaultTimeout: Duration = .seconds(60)

    static let installURL = URL(string: "https://developer.android.com/tools/agents/android-cli")!

    private static let beginMarker = "__PLUME_ANDROID_CLI_BEGIN__"
    private static let endMarker = "__PLUME_ANDROID_CLI_END__"

    private let lock = NSLock()
    private var cachedLocation: URL?
    private let discover: @Sendable () -> URL?

    init(discover: @escaping @Sendable () -> URL? = AndroidCLI.discover) {
        self.discover = discover
    }

    /// A GUI launch has no shell PATH, so this asks the login shell, then tries the usual install
    /// paths. Only a found tool is cached, so installing one shows up on the next check.
    func locate(refresh: Bool = false) async -> URL? {
        if !refresh, let cached = lock.withLock({ cachedLocation }) { return cached }
        let found = await Task.detached(priority: .userInitiated) { [discover] in discover() }.value
        lock.withLock { cachedLocation = found }
        return found
    }

    func run(
        _ arguments: [String],
        timeout: Duration,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> AndroidCLIResult {
        guard let executable = await locate() else { throw AndroidCLIError.notInstalled }
        var environment = ProcessInfo.processInfo.environment
        if let sdk = await AndroidSDKLocator.locate().sdk {
            environment.merge(sdk.launchEnvironment) { _, sdkValue in sdkValue }
            if let adbDirectory = sdk.adbURL?.deletingLastPathComponent().path {
                environment["PATH"] = [adbDirectory, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
            }
        }
        let result = try await ChildProcess.run(
            executable: executable.path,
            arguments: arguments,
            environment: environment,
            output: Self.leavesDaemon(arguments) ? .file : .pipes,
            timeout: timeout,
            onOutput: onOutput
        )
        return AndroidCLIResult(status: result.status, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut)
    }

    /// `connect` starts a daemon that outlives the command, so its output can't go through pipes.
    private static func leavesDaemon(_ arguments: [String]) -> Bool {
        arguments.starts(with: ["device", "remote", "connect"])
    }

    static func candidatePaths(shellPath: String?, home: String = NSHomeDirectory()) -> [String] {
        [shellPath, "/usr/local/bin/android", "/opt/homebrew/bin/android", home + "/.android/bin/android-cli"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    static func parseShellOutput(_ output: String) -> String? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex)
        else { return nil }
        let path = output[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        // An alias or function prints its definition, not a path.
        return path.hasPrefix("/") ? path : nil
    }

    static func discover() -> URL? {
        let script = "echo \(beginMarker); command -v android; echo \(endMarker)"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let shellPath = ChildProcess.capturedOutput(
            executable: shell, arguments: ["-lic", script], timeout: AndroidSDKLocator.loginShellTimeout
        ).flatMap(parseShellOutput)
        return candidatePaths(shellPath: shellPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
