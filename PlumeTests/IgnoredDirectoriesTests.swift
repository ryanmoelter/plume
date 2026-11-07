import Testing
@testable import Plume

struct IgnoredDirectoriesTests {
    @Test func queriesNameEveryPathAndFolderOnce() {
        #expect(IgnoredDirectories.queries(for: ["build/a/x.o", "build/a/y.o"]) == ["build/a/x.o", "build/a", "build", "build/a/y.o"])
    }

    @Test func anIgnoredFolderCoversEverythingBelowIt() {
        var cache = IgnoredDirectories()
        cache.record(ignored: ["build", "build/a", "build/a/x.o", "notes.log"], above: ["build/a/x.o", "notes.log"])
        #expect(cache.directories == ["build", "build/a"])
        #expect(cache.covers("build/b/z.o"))
        #expect(!cache.covers("notes.log"))
        #expect(!cache.covers("src/a.swift"))
        cache.removeAll()
        #expect(!cache.covers("build/b/z.o"))
    }
}
