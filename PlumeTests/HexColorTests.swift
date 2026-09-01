import Testing
import SwiftUI
@testable import Plume

struct HexColorTests {
    @Test func parsesSixDigitHex() {
        #expect(Color(hex: "ccc2ba") != nil)
    }

    @Test func parsesSixDigitHexWithHashPrefix() {
        #expect(Color(hex: "#ccc2ba") != nil)
    }

    @Test func parsesThreeDigitHex() {
        #expect(Color(hex: "abc") != nil)
    }

    @Test func parsesThreeDigitHexWithHashPrefix() {
        #expect(Color(hex: "#abc") != nil)
    }

    @Test func rejectsWrongLength() {
        #expect(Color(hex: "abcd") == nil)
        #expect(Color(hex: "ab") == nil)
        #expect(Color(hex: "") == nil)
        #expect(Color(hex: "#") == nil)
    }

    @Test func rejectsNonHexCharacters() {
        #expect(Color(hex: "zzzzzz") == nil)
        #expect(Color(hex: "zzz") == nil)
    }
}
