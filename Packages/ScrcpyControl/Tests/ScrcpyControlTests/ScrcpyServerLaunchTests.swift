import Foundation
import Testing
@testable import ScrcpyControl

struct ScrcpyServerLaunchTests {
    static func write(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scrcpy-\(UUID().uuidString).jar")
        try contents.write(to: url)
        return url
    }

    @Test func acceptsAZip() throws {
        let url = try Self.write(Data("PK\u{3}\u{4}rest".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        try ScrcpyServerLaunch.verifyJar(at: url)
    }

    @Test func rejectsAnLFSPointerWithInstructions() throws {
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536
        size 90788

        """
        let url = try Self.write(Data(pointer.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ScrcpyLaunchError.serverJarIsLFSPointer(path: url.path)) {
            try ScrcpyServerLaunch.verifyJar(at: url)
        }
        #expect(ScrcpyLaunchError.serverJarIsLFSPointer(path: url.path).description.contains("git lfs pull"))
    }

    @Test func rejectsOtherFiles() throws {
        let url = try Self.write(Data("<html>".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ScrcpyLaunchError.serverJarNotAZip(path: url.path)) {
            try ScrcpyServerLaunch.verifyJar(at: url)
        }
    }

    @Test func reportsAMissingJar() {
        let url = URL(fileURLWithPath: "/nonexistent/scrcpy-server.jar")
        #expect(throws: ScrcpyLaunchError.serverJarMissing(path: url.path)) {
            try ScrcpyServerLaunch.verifyJar(at: url)
        }
    }

    @Test func formatsTheSocketIDAsEightHexDigits() {
        let launch = ScrcpyServerLaunch(adbURL: URL(fileURLWithPath: "/usr/bin/false"), serial: "x", jarURL: URL(fileURLWithPath: "/x"), version: "5.0.1")
        #expect(launch.scid.count == 8)
        #expect(launch.scid.allSatisfy { $0.isHexDigit })
        #expect(UInt32(launch.scid, radix: 16)! < 0x8000_0000)
        #expect(launch.serverArguments.contains("scid=\(launch.scid)"))
        #expect(!launch.serverArguments.contains { $0.hasPrefix("max_size") })
    }

    @Test func vendoredJarMatchesThePinnedVersion() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plume/Resources/Scrcpy")
        let version = try String(contentsOf: resources.appendingPathComponent("scrcpy-VERSION.txt"), encoding: .utf8)
        #expect(version.hasPrefix("scrcpy \(ScrcpyServerVersion.pinned)\n"))
    }
}
