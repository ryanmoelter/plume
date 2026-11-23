import Foundation
import Testing
@testable import Plume

struct CLIPathTests {
    @Test func absoluteKeepsSymlinksAndResolvedFollowsThem() throws {
        let real = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "cli-path-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appending(path: "cli-path-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        let parent = link.deletingLastPathComponent().path
        #expect(CLIPath.absolute(link.lastPathComponent, from: parent) == link.path)
        #expect(CLIPath.absolute("./a/../" + link.lastPathComponent, from: parent) == link.path)
        #expect(CLIPath.resolved(CLIPath.absolute(link.lastPathComponent, from: parent)) == real.path)
    }
}
