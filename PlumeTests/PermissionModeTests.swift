import Foundation
import Testing

@testable import Plume

struct PermissionModeTests {
    @Test func recognizesEveryOfferedMode() {
        for mode in PermissionMode.allCases {
            #expect(PermissionMode.recognizing(mode.token) == mode)
        }
    }

    /// The CLI accepts these, but the menu does not offer them, so a session
    /// running in one must not map onto a mode we do offer.
    @Test func doesNotRecognizeModesTheMenuOmits() {
        #expect(PermissionMode.recognizing("manual") == nil)
        #expect(PermissionMode.recognizing("dontAsk") == nil)
        #expect(PermissionMode.recognizing("default") == nil)
        #expect(PermissionMode.recognizing("") == nil)
    }
}
