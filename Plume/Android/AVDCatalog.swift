import Foundation

nonisolated struct AVD: Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let directory: URL
    let lcdSize: CGSize?
}

nonisolated enum AVDCatalog {
    static func list(sdk: AndroidSDK, avdHome: URL = defaultAVDHome()) async -> [AVD] {
        await Task.detached(priority: .userInitiated) {
            let output = runListAVDs(sdk: sdk)
            return parseListOutput(output).map { enrich(id: $0, avdHome: avdHome) }
        }.value
    }

    static func defaultAVDHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["ANDROID_AVD_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.android/avd", isDirectory: true)
    }

    /// One AVD id per line; `INFO | ...` log lines are dropped.
    static func parseListOutput(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" | ") }
    }

    static func parseINI(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            result[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func makeAVD(id: String, rootINI: String?, configINI: String?, avdHome: URL) -> AVD {
        let directory = avdDirectory(id: id, rootINI: rootINI, avdHome: avdHome)
        let config = configINI.map(parseINI) ?? [:]
        var size: CGSize?
        if let w = config["hw.lcd.width"].flatMap(Double.init), let h = config["hw.lcd.height"].flatMap(Double.init), w > 0, h > 0 {
            size = CGSize(width: w, height: h)
        }
        return AVD(
            id: id,
            displayName: config["avd.ini.displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? id.replacingOccurrences(of: "_", with: " "),
            directory: directory,
            lcdSize: size
        )
    }

    /// The id is the `.ini` basename; the `.avd` directory name can differ from it.
    static func avdDirectory(id: String, rootINI: String?, avdHome: URL) -> URL {
        if let path = rootINI.flatMap({ parseINI($0)["path"] }), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return avdHome.appending(path: "\(id).avd", directoryHint: .isDirectory)
    }

    private static func enrich(id: String, avdHome: URL) -> AVD {
        let rootINI = try? String(contentsOf: avdHome.appending(path: "\(id).ini"), encoding: .utf8)
        let directory = avdDirectory(id: id, rootINI: rootINI, avdHome: avdHome)
        let configINI = try? String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8)
        return makeAVD(id: id, rootINI: rootINI, configINI: configINI, avdHome: avdHome)
    }

    private static func runListAVDs(sdk: AndroidSDK) -> String {
        let process = Process()
        process.executableURL = sdk.emulatorURL
        process.arguments = ["-list-avds"]
        process.environment = ProcessInfo.processInfo.environment.merging(sdk.launchEnvironment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
