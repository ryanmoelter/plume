import Foundation

/// The print-then-redraw step of a live listing: paint the provisional frame
/// at once, then rewind over it when the resolved frame is ready.
nonisolated enum LiveRedraw {
    /// Prints `provisional`, then `resolve()`'s frame. The resolved frame
    /// replaces the provisional one in place when it fits the terminal, and
    /// prints below it otherwise. Callers fit every line to the terminal's
    /// width, so a frame is one screen row per line.
    static func print(
        provisional: [Chip],
        isTerminal: Bool,
        terminalSize: TerminalSize?,
        console: any CLIConsole,
        resolve: () throws -> [Chip]
    ) rethrows {
        console.print(text(provisional))
        let resolved = try resolve()
        if redrawsInPlace(isTerminal: isTerminal, frameRows: provisional.count, terminalRows: terminalSize?.rows) {
            // Clearing to the end of the screen also clears what is left of a
            // longer old line.
            console.write(TerminalUI.redrawPrefix(lines: provisional.count))
        }
        console.print(text(resolved))
    }

    static func text(_ chips: [Chip]) -> String {
        chips.map(\.text).joined(separator: "\n")
    }

    /// Whether a frame `frameRows` tall can be painted and then redrawn.
    /// The cursor ends a row below the frame, and cursor-up stops at the
    /// top of the screen, so the frame needs a row to spare.
    static func redrawsInPlace(isTerminal: Bool, frameRows: Int, terminalRows: Int?) -> Bool {
        guard isTerminal else { return false }
        guard let terminalRows else { return true }
        return frameRows < terminalRows
    }
}
