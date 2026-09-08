import Testing
@testable import Plume

struct ForgeKindTests {
    @Test(arguments: [
        "git@github.com:ryanmoelter/Plume.git",
        "https://github.com/ryanmoelter/Plume.git",
        "ssh://git@github.com/ryanmoelter/Plume.git",
        "https://user@github.enterprise.internal/team/repo.git",
    ])
    func githubHostsResolve(_ url: String) {
        #expect(ForgeKind.sniffing(originURL: url) == .github)
    }

    /// Plume's own origin. "Shows nothing, quietly" is behavior this repo
    /// depends on until a GitLab client exists.
    @Test(arguments: [
        "git@gitlab.com:ryanmoelter/plume.git",
        "https://gitlab.com/ryanmoelter/plume.git",
        "ssh://git@gitlab.example.com:2222/group/sub/repo.git",
    ])
    func gitlabHostsResolve(_ url: String) {
        #expect(ForgeKind.sniffing(originURL: url) == .gitlab)
    }

    @Test(arguments: [
        "git@bitbucket.org:team/repo.git",
        "https://git.sr.ht/~user/repo",
        "/Users/ryanmoelter/local-repo",
        "",
    ])
    func anythingElseIsNone(_ url: String) {
        #expect(ForgeKind.sniffing(originURL: url) == .none)
    }

    @Test func aMissingOriginIsNone() {
        #expect(ForgeKind.sniffing(originURL: nil) == .none)
    }

    /// A path segment naming a forge must not fool the host sniff.
    @Test func onlyTheHostIsMatched() {
        #expect(ForgeKind.sniffing(originURL: "git@example.com:team/github-mirror.git") == .none)
    }
}
