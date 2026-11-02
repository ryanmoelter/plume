import Darwin
import Foundation

nonisolated struct RunningEmulator: Hashable, Sendable {
    let pid: Int32
    let avdID: String
    let avdName: String
    let avdDirectory: URL?
    let grpcPort: Int
    let grpcToken: String?
    let adbPort: Int?
    let serialPort: Int?
    let version: String?
    let fileURL: URL

    var adbSerial: String? { serialPort.map { "emulator-\($0)" } }
}

nonisolated enum EmulatorDiscoveryFile {
    static func parse(text: String, fileName: String, fileURL: URL? = nil) -> RunningEmulator? {
        guard fileName.hasPrefix("pid_"), fileName.hasSuffix(".ini"),
              let pid = Int32(fileName.dropFirst(4).dropLast(4))
        else { return nil }

        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let grpcPort = fields["grpc.port"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }

        let avdID = fields["avd.id"] ?? ""
        return RunningEmulator(
            pid: pid,
            avdID: avdID,
            avdName: fields["avd.name"] ?? avdID,
            avdDirectory: fields["avd.dir"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            grpcPort: grpcPort,
            grpcToken: fields["grpc.token"].flatMap { $0.isEmpty ? nil : $0 },
            adbPort: fields["port.adb"].flatMap { Int($0) },
            serialPort: fields["port.serial"].flatMap { Int($0) },
            version: fields["emulator.version"],
            fileURL: fileURL ?? URL(fileURLWithPath: fileName)
        )
    }
}

nonisolated enum EmulatorScanner {
    static func runningDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var paths = [NSHomeDirectory() + "/Library/Caches/TemporaryItems/avd/running"]
        if let xdg = environment["XDG_RUNTIME_DIR"], !xdg.isEmpty { paths.append(xdg + "/avd/running") }
        paths.append(NSTemporaryDirectory() + "/avd/running")
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The `qemu-system` check guards against a recycled pid.
    static func scan(
        directory: URL,
        isAlive: (Int32) -> Bool = isProcessAlive,
        processPath: (Int32) -> String? = processPath
    ) -> [RunningEmulator] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [RunningEmulator] = []
        for file in files {
            let name = file.lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let emulator = EmulatorDiscoveryFile.parse(text: text, fileName: name, fileURL: file),
                  isAlive(emulator.pid),
                  processPath(emulator.pid)?.contains("qemu-system") == true
            else { continue }
            result.append(emulator)
        }
        return result.sorted { $0.pid < $1.pid }
    }

    static func modificationDate(of emulator: RunningEmulator) -> Date? {
        try? emulator.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func scanAll(directories: [URL] = runningDirectories()) -> [RunningEmulator] {
        directories.flatMap { scan(directory: $0) }
    }
}
