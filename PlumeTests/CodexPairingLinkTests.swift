import Foundation
import Testing
@testable import Plume

struct CodexPairingLinkTests {
    @Test func opaquePairingCodeIsEncodedInVerifiedSetupRoute() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let code = "opaque+code/&?=# value"
        let url = try #require(CodexPairingLink.url(code: code, expiresAt: now.addingTimeInterval(60), now: now))
        #expect(url.scheme == "https")
        #expect(url.host == "chatgpt.com")
        #expect(url.path == "/codex/pair")
        #expect(url.fragment == nil)
        #expect(url.absoluteString.contains("%2B"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "pairing_code", value: code)])
    }

    @Test func expiredClaimedAndMissingCodesCannotCreateLinks() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(CodexPairingLink.url(code: "code", expiresAt: now, now: now) == nil)
        #expect(CodexPairingLink.url(code: "code", expiresAt: now.addingTimeInterval(-1), now: now) == nil)
        #expect(CodexPairingLink.url(code: "code", expiresAt: now.addingTimeInterval(60), claimed: true, now: now) == nil)
        #expect(CodexPairingLink.url(code: "", expiresAt: now.addingTimeInterval(60), now: now) == nil)
    }
}
