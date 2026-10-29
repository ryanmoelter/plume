import Testing
import Foundation
@testable import Plume

@MainActor
struct CheckoutSubpathTests {
    private func makeRepository() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Android/app"), withIntermediateDirectories: true)
        _ = try GitRunner.run(["init", "-q"], in: dir.path)
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: dir.path)
        return dir
    }

    @Test func aFolderBelowTheTopLevelReportsItsSubpath() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = repo.appendingPathComponent("Android").path
        let facts = try #require(GitRunner.checkoutFacts(containing: path))
        #expect(facts.subpath(of: path) == "Android")
        #expect(facts.subpath(of: path + "/app") == "Android/app")
    }

    @Test func theTopLevelHasNoSubpath() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let facts = try #require(GitRunner.checkoutFacts(containing: repo.path))
        #expect(facts.subpath(of: repo.path) == nil)
        #expect(facts.subpath(of: repo.path + "/") == nil)
    }

    @Test func aSymlinkedSpellingOfTheTopLevelIsStillTheTopLevel() throws {
        let repo = try makeRepository()
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: repo)
        }
        let facts = try #require(GitRunner.checkoutFacts(containing: link.path))
        #expect(facts.subpath(of: link.path) == nil)
        #expect(facts.subpath(of: link.path + "/Android") == "Android")
    }

    @Test func aPathOutsideTheCheckoutHasNoSubpath() throws {
        let facts = CheckoutFacts(projectRoot: "/repo", checkoutRoot: "/repo")
        #expect(facts.subpath(of: "/repository") == nil)
        #expect(facts.subpath(of: "/elsewhere") == nil)
    }
}
