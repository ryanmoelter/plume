import Testing
@testable import Plume

struct ReviewFileTreeTests {
    @Test func aTrailingSlashEntryIsADirectory() {
        let tree = ReviewFileTree(paths: ["vendor/", "lib/nested/", "lib/a.swift"], files: [])
        let root = tree.children[""] ?? []
        #expect(root.map(\.path) == ["lib", "vendor"])
        #expect(root.allSatisfy { $0.isDirectory })
        let lib = tree.children["lib"] ?? []
        #expect(lib.map(\.path) == ["lib/nested", "lib/a.swift"])
        #expect(lib.map(\.isDirectory) == [true, false])
    }
}
