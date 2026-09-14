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
    ///
    /// Cached because every prose font goes through it and the answer cannot
    /// change during a run — registration happens once, at launch.
    /// `availableFontFamilies` enumerates every family on the system, which
    /// measured 40x the cost of a font lookup and made scrolling stutter when
    /// it ran per markdown block.
    static let isProseAvailable: Bool = {
        registerIfNeeded()
        return NSFontManager.shared.availableFontFamilies.contains(prose)
    }()
}

import SwiftUI

extension Font {
    /// Chat prose in the bundled serif, falling back to the system face if
    /// it is missing.
    ///
    /// Libre Baskerville carries only a `wght` axis (400–700), so there is no
    /// optical size to track — the face is the same shape at every size.
    ///
    /// `relativeTo` anchors the size to a text style so Dynamic Type still
    /// scales it. A bare `Font.custom(_:size:)` is fixed at its point size and
    /// ignores the accessibility setting outright.
    static func chatProse(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle
    ) -> Font {
        guard BundledFonts.isProseAvailable else {
            return .system(size: size, weight: weight)
        }
        return .custom(BundledFonts.prose, size: size, relativeTo: textStyle).weight(weight)
    }
}

extension NSFont {
    /// The composer's body font, for its text storage.
    ///
    /// The system face rather than the bundled serif: what the user is typing
    /// should read as input, not as published prose. `ComposerTextStyle`
    /// derives bold and italic from this descriptor.
    nonisolated static func composerBody(ofSize size: CGFloat) -> NSFont {
        .systemFont(ofSize: size)
    }
}
