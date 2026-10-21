import Testing
@testable import Plume

struct LinearStateColorTests {
    private func hex(_ value: String) -> HexRGB { HexRGB(hex: value)! }

    private let mocha: [Int: HexRGB] = [
        1: HexRGB(hex: "f38ba8")!, 2: HexRGB(hex: "a6e3a1")!, 3: HexRGB(hex: "f9e2af")!,
        4: HexRGB(hex: "89b4fa")!, 5: HexRGB(hex: "f5c2e7")!, 6: HexRGB(hex: "94e2d5")!,
    ]

    private func slot(_ color: String, among palette: [Int: HexRGB]) -> Int? {
        LinearStateColor.nearestSlot(to: hex(color), among: palette)
    }

    // Expected slots match Linear's default workflow colors.
    @Test(arguments: [
        ("e2e2e2", nil), ("bec2c8", nil), ("95a2b3", nil),
        ("f2c94c", 3), ("5e6ad2", 4), ("fc7840", 1), ("0f7488", 6),
    ] as [(String, Int?)])
    func fallbackSlotsMapLinearDefaults(color: String, expected: Int?) {
        #expect(slot(color, among: LinearStateColor.fallbackSlots) == expected)
    }

    @Test(arguments: [
        ("e2e2e2", nil), ("bec2c8", nil), ("95a2b3", nil),
        ("f2c94c", 3), ("5e6ad2", 4), ("fc7840", 1), ("0f7488", 4),
    ] as [(String, Int?)])
    func aThemedPaletteMapsLinearDefaults(color: String, expected: Int?) {
        #expect(slot(color, among: mocha) == expected)
    }

    @Test func aGrayCandidateIsNeverChosen() {
        var palette = LinearStateColor.fallbackSlots
        palette[3] = hex("808080")
        #expect(slot("f2c94c", among: palette) != 3)
    }
}
