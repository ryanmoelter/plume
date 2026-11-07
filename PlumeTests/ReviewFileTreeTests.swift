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

    @Test func aSubfolderScopeRootsTheTreeThereAndGathersOutsideChangesUnderDotDot() {
        let files = [
            DiffFileSummary(path: "app/src/a.swift", kind: .modified),
            DiffFileSummary(path: "lib/b.swift", kind: .added),
            DiffFileSummary(path: "README.md", kind: .modified),
        ]
        let paths = ["app/src/a.swift", "app/src/c.swift", "app/d.txt", "lib/b.swift", "lib/e.swift", "README.md"]
        let tree = ReviewFileTree(paths: paths, files: files, scope: "app")

        #expect(tree.children[""]?.map(\.path) == ["app/src", "app/d.txt", ".."])
        #expect(tree.children["app/src"]?.map(\.path) == ["app/src/a.swift", "app/src/c.swift"])
        #expect(tree.children[".."]?.map(\.path) == ["lib", "README.md"])
        #expect(tree.children["lib"]?.map(\.path) == ["lib/b.swift"])
        #expect(tree.changedDescendants[""] == 3)
        #expect(tree.changedDescendants["app/src"] == 1)
        #expect(tree.changedDescendants[".."] == 2)
        #expect(tree.changedDescendants["lib"] == 1)

        let changed = ReviewFileTree(paths: [], files: files, scope: "app")
        #expect(changed.children[""]?.map(\.path) == ["app/src", ".."])
    }
}
