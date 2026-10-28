import Foundation
import Testing
@testable import ScrcpyControl

/// Expected bytes come from scrcpy 5.0.1's `app/tests/test_control_msg_serialize.c` unless noted.
struct ScrcpyControlMessageTests {
    @Test func injectKeycode() {
        let message = ScrcpyControlMessage.injectKeycode(
            action: Android.KeyAction.up,
            keycode: Android.KeyCode.enter,
            repeat: 5,
            metaState: Android.Meta.shiftOn | Android.Meta.shiftLeftOn
        )
        #expect([UInt8](message.encoded()) == [
            0x00,
            0x01,
            0x00, 0x00, 0x00, 0x42,
            0x00, 0x00, 0x00, 0x05,
            0x00, 0x00, 0x00, 0x41,
        ])
    }

    @Test func injectText() {
        #expect([UInt8](ScrcpyControlMessage.injectText("hello, world!").encoded()) == [0x01, 0x00, 0x00, 0x00, 0x0D] + Array("hello, world!".utf8))
    }

    @Test func injectTextTruncatesToTheServerLimit() {
        let bytes = [UInt8](ScrcpyControlMessage.injectText(String(repeating: "a", count: 400)).encoded())
        #expect(bytes.count == 5 + 300)
        #expect(Array(bytes[0..<5]) == [0x01, 0x00, 0x00, 0x01, 0x2C])
    }

    // Not from the C tests: checks the cut never splits a multi-byte character.
    @Test func injectTextTruncatesOnACharacterBoundary() {
        let text = String(repeating: "a", count: 299) + "é"
        let bytes = [UInt8](ScrcpyControlMessage.injectText(text).encoded())
        #expect(bytes.count == 5 + 299)
    }

    @Test func injectTouch() {
        let message = ScrcpyControlMessage.injectTouch(
            action: Android.MotionAction.down,
            pointerID: 0x1234_5678_8765_4321,
            position: ScrcpyPosition(x: 100, y: 200, screenWidth: 1080, screenHeight: 1920),
            pressure: 1,
            actionButton: Android.MotionButton.primary,
            buttons: Android.MotionButton.primary
        )
        #expect([UInt8](message.encoded()) == [
            0x02,
            0x00,
            0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,
            0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xC8,
            0x04, 0x38, 0x07, 0x80,
            0xFF, 0xFF,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
        ])
    }

    @Test func injectScroll() {
        let message = ScrcpyControlMessage.injectScroll(
            position: ScrcpyPosition(x: 260, y: 1026, screenWidth: 1080, screenHeight: 1920),
            hScroll: 16,
            vScroll: -16,
            buttons: 1
        )
        #expect([UInt8](message.encoded()) == [
            0x03,
            0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02,
            0x04, 0x38, 0x07, 0x80,
            0x7F, 0xFF,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x01,
        ])
    }

    // Half of the [-16, 16] range is 0.5 in [-1, 1], which `sc_float_to_i16fp` encodes as 0x4000.
    @Test func injectScrollClampsAndScales() {
        let bytes = [UInt8](ScrcpyControlMessage.injectScroll(
            position: ScrcpyPosition(x: 0, y: 0, screenWidth: 1, screenHeight: 1),
            hScroll: 8,
            vScroll: 100,
            buttons: 0
        ).encoded())
        #expect(Array(bytes[13..<17]) == [0x40, 0x00, 0x7F, 0xFF])
    }

    @Test func backOrScreenOn() {
        #expect([UInt8](ScrcpyControlMessage.backOrScreenOn(action: Android.KeyAction.up).encoded()) == [0x04, 0x01])
    }

    @Test func singleByteMessages() {
        #expect([UInt8](ScrcpyControlMessage.expandNotificationPanel.encoded()) == [0x05])
        #expect([UInt8](ScrcpyControlMessage.expandSettingsPanel.encoded()) == [0x06])
        #expect([UInt8](ScrcpyControlMessage.collapsePanels.encoded()) == [0x07])
        #expect([UInt8](ScrcpyControlMessage.rotateDevice.encoded()) == [0x0B])
        #expect([UInt8](ScrcpyControlMessage.resetVideo.encoded()) == [0x11])
    }

    @Test func setDisplayPower() {
        #expect([UInt8](ScrcpyControlMessage.setDisplayPower(on: true).encoded()) == [0x0A, 0x01])
    }

    @Test func positionFromAPoint() {
        let position = ScrcpyPosition(point: CGPoint(x: 10.6, y: 20.2), screenSize: CGSize(width: 1080, height: 2424))
        #expect(position == ScrcpyPosition(x: 11, y: 20, screenWidth: 1080, screenHeight: 2424))
    }
}

/// Layouts from scrcpy 5.0.1's `server/.../control/DeviceMessageWriter.java`.
struct ScrcpyDeviceMessageParserTests {
    @Test func parsesEachTypeAcrossSplitFeeds() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x02, 0x68, 0x69]
            + [0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
            + [0x02, 0x00, 0x07, 0x00, 0x02, 0xAA, 0xBB]
        var parser = ScrcpyDeviceMessageParser()
        var messages: [ScrcpyDeviceMessage] = []
        for byte in bytes {
            messages += parser.feed(Data([byte]))
        }
        #expect(messages == [
            .clipboard("hi"),
            .ackClipboard(sequence: 0x0102_0304_0506_0708),
            .uhidOutput(id: 7, data: Data([0xAA, 0xBB])),
        ])
    }

    @Test func discardsEverythingAfterAnUnknownType() {
        var parser = ScrcpyDeviceMessageParser()
        #expect(parser.feed(Data([0x09, 0x01, 0x00])).isEmpty)
        #expect(parser.lostSync)
        #expect(parser.feed(Data([0x01, 0, 0, 0, 0, 0, 0, 0, 1])).isEmpty)
    }
}
