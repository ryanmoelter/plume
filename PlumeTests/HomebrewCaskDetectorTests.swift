import Foundation
import Testing

@testable import Plume

/// `HomebrewCaskDetector` against a scratch directory tree.
@MainActor
struct HomebrewCaskDetectorTests {
    private func makeScratch() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "homebrew-cask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func noPrefixHasACaskroomIsNotACaskInstall() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [scratch]) == false)
    }

    @Test func aCaskroomPlumeDirectoryIsACaskInstall() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try FileManager.default.createDirectory(
            at: scratch.appending(path: "Caskroom/plume"),
            withIntermediateDirectories: true
        )

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [scratch]) == true)
    }

    @Test func aFileNamedCaskroomPlumeIsNotACaskInstall() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try FileManager.default.createDirectory(
            at: scratch.appending(path: "Caskroom"),
            withIntermediateDirectories: true
        )
        try Data().write(to: scratch.appending(path: "Caskroom/plume"))

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [scratch]) == false)
    }

    @Test func aCaskroomUnderAnySearchedPrefixCounts() throws {
        let first = try makeScratch()
        let second = try makeScratch()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        try FileManager.default.createDirectory(
            at: second.appending(path: "Caskroom/plume"),
            withIntermediateDirectories: true
        )

        #expect(HomebrewCaskDetector.isCaskInstall(prefixes: [first, second]) == true)
    }
}
