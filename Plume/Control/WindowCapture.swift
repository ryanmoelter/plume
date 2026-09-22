#if DEBUG
import AppKit

/// Screenshots come from the window server rather than from drawing the
/// view tree, because `CGWindowListCreateImage` returns real pixels even
/// while the session reports itself locked, where a `cacheDisplay` capture
/// has come back blank. It captures a process's own windows with no Screen
/// Recording grant. The SDK hides it from Swift as "use ScreenCaptureKit",
/// which does need one, so it is bound by symbol name. The array variant
/// returns nil here; one window per call works.
@MainActor
enum WindowCapture {
    private static let includingWindow: UInt32 = 1 << 3
    private static let boundsIgnoreFraming: UInt32 = 1 << 0
    private static let bestResolution: UInt32 = 1 << 3

    /// The window's frame, without its shadow, at backing resolution.
    static func image(of window: NSWindow) -> CGImage? {
        cgWindowListCreateImage(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }

    /// True when a grid of samples all share one color. A driven window is
    /// never one flat color, so a uniform capture means the window server
    /// gave back nothing: the display is asleep, the session is locked, or
    /// the window is off screen.
    static func isUniform(_ image: CGImage) -> Bool {
        let width = 32, height = 32
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let pixels = data.assumingMemoryBound(to: UInt32.self)
        let first = pixels[0]
        return (1..<(width * height)).allSatisfy { pixels[$0] == first }
    }

    /// Why a capture might have come back blank, for the error message.
    static var displayState: String {
        var notes: [String] = []
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { notes.append("display asleep") }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            notes.append("session locked")
        }
        return notes.isEmpty ? "display awake and unlocked" : notes.joined(separator: ", ")
    }

    /// Draws `top` over `bottom`, scaled to it; the overlay panel and the
    /// content view have the same bounds, so no offset is needed.
    static func composite(_ top: CGImage, over bottom: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: bottom.width, height: bottom.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: bottom.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height)
        context.draw(bottom, in: rect)
        context.draw(top, in: rect)
        return context.makeImage()
    }
}

@_silgen_name("CGWindowListCreateImage")
private func cgWindowListCreateImage(_ screenBounds: CGRect, _ listOption: UInt32, _ windowID: UInt32, _ imageOption: UInt32) -> Unmanaged<CGImage>?
#endif
