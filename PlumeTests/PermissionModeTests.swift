import Foundation
import Testing

@testable import Plume

struct PermissionModeTests {
    @Test func recognizesEveryOfferedMode() {
        for mode in PermissionMode.allCases {
            #expect(PermissionMode.recognizing(mode.token) == mode)
        }
    }

    /// The CLI accepts these, but this enum has no case for them, so a
    /// session running in one must not map onto a mode we do offer.
    @Test func doesNotRecognizeModesTheEnumOmits() {
        #expect(PermissionMode.recognizing("dontAsk") == nil)
        #expect(PermissionMode.recognizing("default") == nil)
        #expect(PermissionMode.recognizing("") == nil)
    }

    /// A session already running in bypass, or reporting the new manual
    /// mode, has to map back onto a real selection even while the picker
    /// hides bypass by default.
    @Test func recognizesBypassAndManualRegardlessOfPickerVisibility() {
        #expect(PermissionMode.recognizing("bypassPermissions") == .bypassPermissions)
        #expect(PermissionMode.recognizing("manual") == .manual)
    }

    @Test func offeredHidesBypassByDefault() {
        let offered = PermissionMode.offered(showsBypassPermissions: false)
        #expect(!offered.contains(.bypassPermissions))
        #expect(offered.contains(.manual))
        #expect(offered.contains(.plan))
        #expect(offered.contains(.acceptEdits))
        #expect(offered.contains(.auto))
    }

    @Test func offeredIncludesBypassWhenShown() {
        let offered = PermissionMode.offered(showsBypassPermissions: true)
        #expect(offered.contains(.bypassPermissions))
        #expect(offered.count == PermissionMode.allCases.count)
    }

    @Test func defaultOfferedHidesBypassByDefault() {
        let offered = PermissionModeDefault.offered(showsBypassPermissions: false)
        #expect(!offered.contains(.bypassPermissions))
        #expect(offered.contains(.manual))
        #expect(offered.contains(.followClaudeCode))
    }

    @Test func defaultOfferedIncludesBypassWhenShown() {
        let offered = PermissionModeDefault.offered(showsBypassPermissions: true)
        #expect(offered.contains(.bypassPermissions))
        #expect(offered.count == PermissionModeDefault.allCases.count)
    }

    /// A default stored as bypass before the setting existed still resolves
    /// to bypass, rather than crashing or silently falling back, even while
    /// the picker hides it.
    @Test func storedBypassDefaultStillResolves() {
        #expect(PermissionModeDefault.bypassPermissions.permissionMode == .bypassPermissions)
    }
}
