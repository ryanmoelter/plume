import Foundation
import Testing
@testable import Plume

struct EmulatorDiscoveryTests {
    private func makeDirectory(files: [String: Int]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "emu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, port) in files {
            try "avd.id=Test\ngrpc.port=\(port)\n".write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    @Test func keepsLiveQemuProcesses() throws {
        let directory = try makeDirectory(files: ["pid_10.ini": 8554])
        let found = EmulatorScanner.scan(directory: directory, isAlive: { _ in true }, processPath: { _ in "/sdk/qemu/qemu-system-aarch64" })
        #expect(found.map(\.pid) == [10])
        #expect(found.first?.fileURL.lastPathComponent == "pid_10.ini")
    }

    @Test func filtersDeadPids() throws {
        let directory = try makeDirectory(files: ["pid_10.ini": 8554, "pid_11.ini": 8556])
        let found = EmulatorScanner.scan(directory: directory, isAlive: { $0 == 11 }, processPath: { _ in "/x/qemu-system-aarch64" })
        #expect(found.map(\.pid) == [11])
    }

    @Test func filtersReusedPidsThatAreNotQemu() throws {
        let directory = try makeDirectory(files: ["pid_10.ini": 8554])
        let found = EmulatorScanner.scan(directory: directory, isAlive: { _ in true }, processPath: { _ in "/usr/bin/ssh" })
        #expect(found.isEmpty)
    }

    @Test func ignoresNonMatchingFileNames() throws {
        let directory = try makeDirectory(files: ["notes.ini": 1, "pid_x.ini": 2])
        try FileManager.default.createDirectory(at: directory.appending(path: "12"), withIntermediateDirectories: true)
        let found = EmulatorScanner.scan(directory: directory, isAlive: { _ in true }, processPath: { _ in "qemu-system" })
        #expect(found.isEmpty)
    }

    @Test func missingDirectoryYieldsNothing() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "nope-\(UUID().uuidString)")
        #expect(EmulatorScanner.scan(directory: missing).isEmpty)
    }

    @Test func runningDirectoriesHonorXDGAndDedupe() {
        let dirs = EmulatorScanner.runningDirectories(environment: ["XDG_RUNTIME_DIR": "/run/user/1"])
        #expect(dirs.map(\.path).contains("/run/user/1/avd/running"))
        #expect(Set(dirs.map(\.path)).count == dirs.count)
    }

    @MainActor @Test func refreshPublishesRunningList() async throws {
        let directory = try makeDirectory(files: [:])
        let discovery = EmulatorDiscovery(directories: [directory])
        await discovery.refresh()
        #expect(discovery.running.isEmpty)
    }
}
