import Darwin
import Foundation

/// Where a command's output goes and its prompts come from. `StandardConsole`
/// is the terminal; `BufferConsole` captures both streams for tests.
nonisolated protocol CLIConsole: AnyObject {
    /// Writes to stdout as-is, adding no newline.
    func write(_ text: String)
    /// Writes to stderr as-is, adding no newline.
    func writeError(_ text: String)
    /// Writes `prompt` to stdout and reads one line without its newline.
    /// Nil at end of input.
    func readLine(prompt: String) -> String?
    var stdoutIsTerminal: Bool { get }
    var stdinIsTerminal: Bool { get }
    /// The size of the terminal stdout writes to, or nil when it has none
    /// or reports none.
    var terminalSize: TerminalSize? { get }
}

nonisolated struct TerminalSize: Equatable, Sendable {
    var columns: Int
    var rows: Int
}

nonisolated extension CLIConsole {
    func print(_ line: String = "") {
        write(line + "\n")
    }

    func printError(_ line: String) {
        writeError(line + "\n")
    }
}

nonisolated final class StandardConsole: CLIConsole {
    init() {}

    func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    func readLine(prompt: String) -> String? {
        write(prompt)
        return Swift.readLine(strippingNewline: true)
    }

    var stdoutIsTerminal: Bool { isatty(STDOUT_FILENO) == 1 }
    var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    var terminalSize: TerminalSize? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row))
    }
}

/// Captures output and answers prompts from a script, for tests.
nonisolated final class BufferConsole: CLIConsole {
    private(set) var stdout = ""
    private(set) var stderr = ""
    /// Every prompt shown, in order.
    private(set) var prompts: [String] = []
    /// Answers handed out in order; once empty, `readLine` reports end of
    /// input.
    var replies: [String]
    var stdoutIsTerminal: Bool
    var stdinIsTerminal: Bool
    var terminalSize: TerminalSize?

    init(replies: [String] = [], stdoutIsTerminal: Bool = false, stdinIsTerminal: Bool = false, terminalSize: TerminalSize? = nil) {
        self.replies = replies
        self.stdoutIsTerminal = stdoutIsTerminal
        self.stdinIsTerminal = stdinIsTerminal
        self.terminalSize = terminalSize
    }

    func write(_ text: String) {
        stdout += text
    }

    func writeError(_ text: String) {
        stderr += text
    }

    func readLine(prompt: String) -> String? {
        stdout += prompt
        prompts.append(prompt)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}
