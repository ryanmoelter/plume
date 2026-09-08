import Testing
import Foundation
@testable import Plume

/// Which pull request a branch's column shows when several share the branch
/// name: a head in this repository beats a fork's, open beats closed, and
/// the highest number breaks the tie.
struct GitHubPickBestTests {
    private func decode(_ nodesJSON: String, owner: String = "me") throws -> PullRequest? {
        let json = """
        {"data":{"repository":{"owner":{"login":"\(owner)"},"b0":{"nodes":[\(nodesJSON)]}}}}
        """
        return try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])["main"] ?? nil
    }

    private func node(_ number: Int, _ state: String, owner: String) -> String {
        """
        {"number":\(number),"state":"\(state)","isDraft":false,
         "headRepositoryOwner":{"login":"\(owner)"}}
        """
    }

    @Test func aHeadInThisRepositoryBeatsAForksHigherNumber() throws {
        let picked = try decode([
            node(200, "OPEN", owner: "someone-else"),
            node(100, "OPEN", owner: "me"),
        ].joined(separator: ","))
        #expect(picked?.number == 100)
    }

    @Test func openBeatsClosedAtTheSameOwner() throws {
        let picked = try decode([
            node(200, "CLOSED", owner: "me"),
            node(100, "OPEN", owner: "me"),
        ].joined(separator: ","))
        #expect(picked?.number == 100)
    }

    @Test func theHighestNumberBreaksTheTie() throws {
        let picked = try decode([
            node(100, "OPEN", owner: "me"),
            node(300, "OPEN", owner: "me"),
            node(200, "OPEN", owner: "me"),
        ].joined(separator: ","))
        #expect(picked?.number == 300)
    }

    @Test func aForkOnlyBranchStillResolves() throws {
        let picked = try decode(node(42, "OPEN", owner: "someone-else"))
        #expect(picked?.number == 42)
    }

    @Test func closedOnlyBranchesStillResolve() throws {
        let picked = try decode([
            node(10, "MERGED", owner: "me"),
            node(20, "CLOSED", owner: "me"),
        ].joined(separator: ","))
        #expect(picked?.number == 20)
    }
}
