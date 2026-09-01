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
    /// The typographic family name, which is what `Font.custom` resolves.
    /// Note the compatibility family is `Newsreader 16pt` — the default
    /// `opsz` instance — so the two names are not interchangeable.
    static let newsreader = "Newsreader"

    private static var registered = false

    /// Registers every bundled font once. Safe to call repeatedly.
    static func registerIfNeeded() {
        guard !registered else { return }
        registered = true

        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(newsreader) {
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
    static var isNewsreaderAvailable: Bool {
        registerIfNeeded()
        return NSFontManager.shared.availableFontFamilies.contains(newsreader)
    }
}

import SwiftUI

extension Font {
    /// Chat prose in Newsreader, falling back to the system face if the
    /// bundled font is missing.
    ///
    /// The family carries an `opsz` axis (6–72), which is what keeps a
    /// variable serif looking right across the 11–28pt range `chatFontSize`
    /// allows. SwiftUI reaches it by asking for the face at the size it will
    /// render at, which is what `Font.custom(_:size:)` does — the optical
    /// size then tracks the point size for free.
    static func chatProse(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard BundledFonts.isNewsreaderAvailable else {
            return .system(size: size, weight: weight)
        }
        return .custom(BundledFonts.newsreader, size: size).weight(weight)
    }
}
