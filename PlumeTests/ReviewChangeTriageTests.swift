import Testing
@testable import Plume

struct ReviewChangeTriageTests {
    private let triage = ReviewChangeTriage(
        knownPaths: ["src/a.swift", "vendor/", "sub", "docs"],
        nestedRepositories: ["vendor", "sub"],
        headRef: "refs/heads/topic",
        baseRef: "refs/remotes/origin/release/2.0"
    )

    @Test func aKnownFileRelistsAndIsTouched() {
        let outcome = triage.triage([.workingTree("src/a.swift")])
        #expect(outcome == .init(relists: true, touched: ["src/a.swift"]))
    }

    @Test func anUnknownFileWaitsOnIgnoreRules() {
        let outcome = triage.triage([.workingTree("src/new.swift")])
        #expect(outcome == .init(touched: ["src/new.swift"], unknown: ["src/new.swift"]))
    }

    @Test func writesInsideNestedRepositoriesAndSubmodulesAreIgnored() {
        let outcome = triage.triage([.workingTree("vendor/lib/x.c"), .workingTree("sub/y.c")])
        #expect(outcome == .init())
    }

    @Test func aFileReplacedByADirectoryIsNotANestedRepository() {
        let outcome = triage.triage([.workingTree("docs/guide.md")])
        #expect(outcome == .init(touched: ["docs/guide.md"], unknown: ["docs/guide.md"]))
    }

    @Test func onlyHeadTheBranchTheBaseAndPackedRefsRelist() {
        #expect(triage.triage([.ref("refs/heads/other"), .ref("refs/tags/v1")]) == .init())
        #expect(triage.triage([.ref("refs/heads/topic")]) == .init(relists: true))
        #expect(triage.triage([.ref("packed-refs")]) == .init(relists: true))
        #expect(triage.triage([.ref("HEAD")]) == .init(relists: true, headMoved: true))
        #expect(
            triage.triage([.ref("refs/remotes/origin/release/2.0")]) == .init(relists: true, baseRefChanged: true)
        )
        #expect(triage.triage([.ref("refs/remotes/origin/HEAD")]) == .init(relists: true, baseRefChanged: true))
    }

    @Test func indexChangesRelistWithoutTouchingAnything() {
        #expect(triage.triage([.index]) == .init(relists: true))
    }
}
