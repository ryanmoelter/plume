import Testing
@testable import Plume

struct LinearIdentifierTests {
    @Test func findsIdentifierInBranch() {
        #expect(LinearIdentifier.candidates(inBranch: "ryanm/plume-102-integrate-with-linear") == ["PLUME-102"])
        #expect(LinearIdentifier.candidates(inBranch: "feature/DROID-45_fix") == ["DROID-45"])
        #expect(LinearIdentifier.candidates(inBranch: "plume-7") == ["PLUME-7"])
    }

    @Test func requiresBoundaryBeforeKey() {
        #expect(LinearIdentifier.candidates(inBranch: "abcplume-1").isEmpty)
        #expect(LinearIdentifier.candidates(inBranch: "ryanm/plume-102-integrate-5x").count == 1)
    }

    @Test func numberOnlyPiecesYieldNothing() {
        #expect(LinearIdentifier.candidates(inBranch: "ryanm/fix-the-thing").isEmpty)
        #expect(LinearIdentifier.candidates(inBranch: "main").isEmpty)
        #expect(LinearIdentifier.candidates(inBranch: "").isEmpty)
        #expect(LinearIdentifier.candidates(inBranch: "plume-102a").isEmpty)
    }

    @Test func multipleAreDeduplicatedInOrder() {
        #expect(LinearIdentifier.candidates(inBranch: "droid-1/plume-2-plume-2-droid-1") == ["DROID-1", "PLUME-2"])
    }

    @Test func filterKeepsKnownTeams() {
        let candidates = LinearIdentifier.candidates(inBranch: "ryanm/utf-8-plume-3")
        #expect(candidates == ["UTF-8", "PLUME-3"])
        #expect(LinearIdentifier.filter(candidates, teamKeys: ["PLUME"]) == ["PLUME-3"])
        #expect(LinearIdentifier.filter(LinearIdentifier.candidates(inBranch: "utf-8"), teamKeys: ["PLUME"]).isEmpty)
    }

    @Test func normalizeAcceptsIdentifiersAndURLs() {
        #expect(LinearIdentifier.normalize("  plume-102 ") == "PLUME-102")
        #expect(LinearIdentifier.normalize("https://linear.app/plume-term/issue/PLUME-102/integrate-with-linear") == "PLUME-102")
        #expect(LinearIdentifier.normalize("https://linear.app/plume-term/issue/plume-9") == "PLUME-9")
    }

    @Test func normalizeRejectsJunk() {
        for junk in ["", "hello", "PLUME", "PLUME-", "-12", "PLUME-12-3", "925ea779-451c-4723-b755-e0828e5912c3", "1PLUME-2", "PLUME-1a", "TOOLONGKEY-1"] {
            #expect(LinearIdentifier.normalize(junk) == nil, "\(junk)")
        }
    }

    @Test func teamKeyIsUppercasePrefix() {
        #expect(LinearIdentifier.teamKey(of: "plume-102") == "PLUME")
    }
}
