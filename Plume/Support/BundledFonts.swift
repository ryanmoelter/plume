import AppKit
import CoreText
import Foundation
import os

/// Registers the fonts Plume ships with, so `Font.custom` can find them.
///
/// `ATSApplicationFontsPath` is not one of the keys Xcode's Info.plist
/// generator understands, and the project has no plist file to add it to, so
/// registration happens here instead. It also frees the fonts from any
/// particular bundle layout: file-system synchronized groups flatten
/// resources into `Contents/Resources` rather than preserving the source
/// directory.
enum BundledFonts {
    /// The family name `Font.custom` resolves.
    static let prose = "Libre Baskerville"

    private static var registered = false

    /// Registers every bundled font once. Safe to call repeatedly.
    static func registerIfNeeded() {
        guard !registered else { return }
        registered = true

        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("LibreBaskerville") {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // A font that fails to register is a styling problem, not a
                // reason to fail launch — the chat falls back to the system
                // face.
                Log.app.error(
                    "Failed to register \(url.lastPathComponent, privacy: .public): \(String(describing: error?.takeUnretainedValue()), privacy: .public)"
                )
            }
        }
    }

    /// Whether the family resolved, so a caller can fall back rather than
    /// silently rendering in a substitute face.
    static var isProseAvailable: Bool {
        registerIfNeeded()
        return NSFontManager.shared.availableFontFamilies.contains(prose)
    }
}

import SwiftUI

extension Font {
    /// Chat prose in the bundled serif, falling back to the system face if
    /// it is missing.
    ///
    /// Libre Baskerville carries only a `wght` axis (400–700), so there is no
    /// optical size to track — the face is the same shape at every size.
    static func chatProse(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard BundledFonts.isProseAvailable else {
            return .system(size: size, weight: weight)
        }
        return .custom(BundledFonts.prose, size: size).weight(weight)
    }
}

extension NSFont {
    /// The AppKit half of `Font.chatProse`, for the composer's text storage.
    ///
    /// Emphasis is derived from this descriptor rather than the system one,
    /// so bold and italic resolve within the bundled family — the italic
    /// comes from the italic file instead of being synthesized by slanting.
    static func chatProse(ofSize size: CGFloat) -> NSFont {
        guard BundledFonts.isProseAvailable, let font = NSFont(name: BundledFonts.prose, size: size) else {
            return .systemFont(ofSize: size)
        }
        return font
    }
}
