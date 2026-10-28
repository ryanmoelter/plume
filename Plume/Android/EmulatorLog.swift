import OSLog

/// Debug builds only, until the emulator tab ships: a Release build logs
/// nothing about emulators.
nonisolated enum EmulatorLog {
    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        let message = message()
        Log.emulator.info("\(message, privacy: .public)")
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        let message = message()
        Log.emulator.error("\(message, privacy: .public)")
        #endif
    }
}
