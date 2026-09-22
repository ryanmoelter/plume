import Testing
import Foundation
@testable import Plume

struct ClaudeTrustStoreTests {
    private func writeFixture(_ json: String) -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString).json").path
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func trustedPathReadsTrue() {
        let path = writeFixture("""
        {"projects": {"/Users/ryan/repo": {"hasTrustDialogAccepted": true}}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(ClaudeTrustStore.isTrusted("/Users/ryan/repo", claudeJSONPath: path))
    }

    @Test func untrustedPathReadsFalse() {
        let path = writeFixture("""
        {"projects": {"/Users/ryan/repo": {"hasTrustDialogAccepted": false}}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!ClaudeTrustStore.isTrusted("/Users/ryan/repo", claudeJSONPath: path))
    }

    @Test func entryAbsentReadsFalse() {
        let path = writeFixture("""
        {"projects": {"/Users/ryan/other": {"hasTrustDialogAccepted": true}}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!ClaudeTrustStore.isTrusted("/Users/ryan/repo", claudeJSONPath: path))
    }

    @Test func missingFileReadsFalse() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json").path

        #expect(!ClaudeTrustStore.isTrusted("/Users/ryan/repo", claudeJSONPath: path))
    }

    @Test func trustIsInheritedFromAnAncestor() {
        let path = writeFixture("""
        {"projects": {"/Users/ryan/repo": {"hasTrustDialogAccepted": true}}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(ClaudeTrustStore.isTrusted("/Users/ryan/repo/.plume/worktrees/x", claudeJSONPath: path))
    }

    /// The CLI records nothing for a directory it trusted by inheritance, so
    /// the nearest explicit answer is the only one there is to honor.
    @Test func nearerAncestorOverridesAFartherOne() {
        let path = writeFixture("""
        {"projects": {
          "/Users/ryan": {"hasTrustDialogAccepted": true},
          "/Users/ryan/repo": {"hasTrustDialogAccepted": false}
        }}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!ClaudeTrustStore.isTrusted("/Users/ryan/repo/sub", claudeJSONPath: path))
        #expect(ClaudeTrustStore.isTrusted("/Users/ryan/other", claudeJSONPath: path))
    }

    @Test func anUnrelatedSiblingIsNotTrusted() {
        let path = writeFixture("""
        {"projects": {"/Users/ryan/repo": {"hasTrustDialogAccepted": true}}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!ClaudeTrustStore.isTrusted("/Users/ryan/repo-other", claudeJSONPath: path))
    }

    @Test func selfAndAncestorsRunsNearestFirstAndEndsAtRoot() {
        #expect(ClaudeTrustStore.selfAndAncestors(of: "/a/b/c") == ["/a/b/c", "/a/b", "/a", "/"])
    }

    @Test func malformedJSONReadsFalse() {
        let path = writeFixture("{not valid json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!ClaudeTrustStore.isTrusted("/Users/ryan/repo", claudeJSONPath: path))
    }
}
