import Darwin
import Foundation
import Observation

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

    static func scanAll(directories: [URL] = runningDirectories()) -> [RunningEmulator] {
        directories.flatMap { scan(directory: $0) }
    }
}

struct EmulatorWaitTimeout: LocalizedError {
    let avdID: String
    var errorDescription: String? { "\(avdID) did not finish starting in time" }
}

/// Tracks emulators already running, whoever started them. Idle until retained.
@MainActor @Observable
final class EmulatorDiscovery {
    static let shared = EmulatorDiscovery()

    private(set) var running: [RunningEmulator] = []

    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private let directories: [URL]

    init(directories: [URL] = EmulatorScanner.runningDirectories()) {
        self.directories = directories
    }

    func retain() {
        retainCount += 1
        guard retainCount == 1 else { return }
        startWatching()
        scheduleRescan(after: .zero)
    }

    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        guard retainCount == 0 else { return }
        stopWatching()
    }

    func refresh() async {
        let directories = directories
        let found = await Task.detached { EmulatorScanner.scanAll(directories: directories) }.value
        if found != running { running = found }
    }

    /// Matches on avd id and a file newer than the launch, not on pid, since the file names qemu's pid.
    func waitForEmulator(avdID: String, newerThan launch: Date, timeout: Duration = .seconds(120)) async throws -> RunningEmulator {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            await refresh()
            if let match = running.first(where: { $0.avdID == avdID && Self.modified($0.fileURL) >= launch }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EmulatorWaitTimeout(avdID: avdID)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func scheduleRescan(after delay: Duration) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.retainCount > 0 else { return }
            await self.refresh()
        }
    }

    private func startWatching() {
        for directory in directories {
            var watched = directory
            while !FileManager.default.fileExists(atPath: watched.path), watched.path != "/" {
                watched = watched.deletingLastPathComponent()
            }
            let descriptor = open(watched.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRescan(after: .milliseconds(200)) }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        // Covers a missing directory, whose ancestor sees only coarse changes, and a pid dying without touching the file.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan(after: .zero) }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopWatching() {
        sources.forEach { $0.cancel() }
        sources = []
        timer?.cancel()
        timer = nil
        debounce?.cancel()
        debounce = nil
    }
}
