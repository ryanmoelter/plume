import Foundation

/// The line that loads `plume init zsh --aliases`, and adding it to the
/// user's `.zshrc` once.
nonisolated enum ZshrcSetup {
    /// Names `plume` rather than a path: the functions it defines call
    /// `command plume`, so the tool has to be on PATH whatever this says.
    static let initLine = #"eval "$(plume init zsh --aliases)""#

    /// Whether any uncommented line already loads the integration, with or
    /// without `--aliases` or `--alias` flags, so a hand-written variant counts.
    static func containsInitLine(_ contents: String) -> Bool {
        contents.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("plume init zsh")
        }
    }

    /// What to append to `contents` so it ends with the line.
    static func appendix(for contents: String) -> String {
        let separator = contents.isEmpty || contents.hasSuffix("\n") ? "" : "\n"
        return separator + initLine + "\n"
    }

    static func isAdded(to file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8)).map(containsInitLine) ?? false
    }

    /// Appends the line unless it is already there, creating the file if
    /// needed. Appends through a file handle rather than rewriting the
    /// file, so a `.zshrc` that is a symlink into a dotfiles repository
    /// stays one.
    static func add(to file: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(appendix(for: "").utf8).write(to: file)
            return
        }
        let contents = try String(contentsOf: file, encoding: .utf8)
        guard !containsInitLine(contents) else { return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendix(for: contents).utf8))
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
