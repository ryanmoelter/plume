import Foundation

/// The line that loads `plume init zsh`, and adding it to the
/// user's `.zshrc` once.
nonisolated enum ZshrcSetup {
    /// Names `plume` rather than a path: the `wt` function and `stack` alias
    /// it defines run `plume`, so the tool has to be on PATH whatever this
    /// says.
    static let initLine = recommendedLine(executables: [:])

    /// The line that defines the bare `wt` function and `stack` alias no other
    /// tool already provides. `executables` maps each name to the files it
    /// resolves to on the user's PATH; a file inside a Plume bundle is
    /// Plume's own link and never counts.
    static func recommendedLine(executables: [String: [URL]]) -> String {
        let taken = Set(ShellIntegration.aliasedSubcommands.filter { name in
            executables[name, default: []].contains { !CommandLineHelper.isInsidePlumeBundle($0) }
        })
        let flags: String
        switch taken.count {
        case 0: flags = " --aliases"
        case ShellIntegration.aliasedSubcommands.count: flags = ""
        default: flags = ShellIntegration.aliasedSubcommands
            .filter { !taken.contains($0) }
            .map { " --alias \($0)" }
            .joined()
        }
        return "eval \"$(plume init zsh\(flags))\""
    }

    /// Each of `wt` and `stack` mapped to the executables of that name in
    /// `directories`, with symlinks resolved. Reads the file system only.
    static func executables(in directories: [String]) -> [String: [URL]] {
        let manager = FileManager.default
        var found: [String: [URL]] = [:]
        for name in ShellIntegration.aliasedSubcommands {
            for directory in directories where !directory.isEmpty {
                let candidate = URL(fileURLWithPath: directory).appending(path: name)
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      manager.isExecutableFile(atPath: candidate.path)
                else { continue }
                found[name, default: []].append(candidate.resolvingSymlinksInPath())
            }
        }
        return found
    }

    /// Whether any uncommented line already loads the integration, with or
    /// without `--aliases` or `--alias` flags, so a hand-written variant counts.
    static func containsInitLine(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("plume init zsh")
        }
    }

    /// What to append to `contents` so it ends with `line`.
    static func appendix(for contents: String, line: String = initLine) -> String {
        let separator = contents.isEmpty || contents.hasSuffix("\n") ? "" : "\n"
        return separator + line + "\n"
    }

    static func isAdded(to file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8)).map(containsInitLine) ?? false
    }

    /// Appends the line unless it is already there, creating the file if
    /// needed. Appends through a file handle rather than rewriting the
    /// file, so a `.zshrc` that is a symlink into a dotfiles repository
    /// stays one.
    static func add(to file: URL, line: String = initLine) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(appendix(for: "", line: line).utf8).write(to: file)
            return
        }
        let contents = try String(contentsOf: file, encoding: .utf8)
        guard !containsInitLine(contents) else { return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendix(for: contents, line: line).utf8))
    }

    /// `$ZDOTDIR/.zshrc`, or `~/.zshrc` when `zdotdir` is unset or empty.
    static func zshrcURL(zdotdir: String?, home: URL = URL.homeDirectory) -> URL {
        guard let zdotdir, !zdotdir.isEmpty else { return home.appending(path: ".zshrc") }
        return URL(fileURLWithPath: (zdotdir as NSString).expandingTildeInPath).appending(path: ".zshrc")
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The `.zshrc` zsh itself would read. A GUI-launched app rarely
    /// inherits `ZDOTDIR`, which is usually set in `~/.zshenv`, so this asks
    /// zsh. Blocks on a process, so call it off the main actor.
    static func resolveZshrcURL() -> URL {
        let result = try? CLIProcess.run(["/bin/zsh", "-c", #"print -r -- "$ZDOTDIR""#], check: false)
        let reported = result?.status == 0
            ? result?.stdout.trimmingCharacters(in: .newlines)
            : ProcessInfo.processInfo.environment["ZDOTDIR"]
        return zshrcURL(zdotdir: reported)
    }
}
