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

    /// The family name `Font.custom` resolves for chat code.
    static let code = "Cascadia Code NF"

    private static var registered = false

    /// Registers every bundled font once. Safe to call repeatedly.
    static func registerIfNeeded() {
        guard !registered else { return }
        registered = true

        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("LibreBaskerville")
            || url.lastPathComponent.hasPrefix("CascadiaCode") {
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

    /// Same reasoning as `isProseAvailable`, for the bundled code face.
    static let isCodeAvailable: Bool = {
        registerIfNeeded()
        return NSFontManager.shared.availableFontFamilies.contains(code)
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

    /// Chat code — inline spans and fenced blocks — in the resolved code
    /// family, falling back to the system monospace face if nothing is
    /// available.
    ///
    /// Resolution order: the user's own ghostty `font-family`, if set, beats
    /// the bundled Cascadia Code NF, which beats the system mono face.
    /// `GhosttyRuntime.shared` is read here (rather than taken as a
    /// parameter) since it is resolved once, at startup, and every call site
    /// wants the same answer.
    ///
    /// The face and weight come from the config's `font-style` and
    /// `font-weight` for the same reason the family does — code in chat should
    /// read as it does in the terminal. A config that names a family but no
    /// style therefore gets that family's regular face, exactly as the
    /// terminal would, rather than inheriting a style it never asked for.
    ///
    /// Passing a weight overrides both, for a caller that needs a particular
    /// weight whatever the user configured.
    @MainActor
    static func chatCode(size: CGFloat, weight: Font.Weight? = nil) -> Font {
        let runtime = GhosttyRuntime.shared
        // An explicit weight is a caller's override and beats the config.
        if let weight {
            guard let family = configuredFamily else {
                return .system(size: size, weight: weight, design: .monospaced)
            }
            return resolved(family: family, style: nil, weight: weight, size: size)
        }
        guard let family = runtime.resolvedCodeFontFamily else {
            guard BundledFonts.isCodeAvailable else {
                return .system(size: size, weight: .regular, design: .monospaced)
            }
            // The bundled face's own default, not a fallback for a config that
            // asked for something else: Cascadia's regular weight reads heavy
            // beside the prose around it.
            return resolved(family: BundledFonts.code, style: bundledStyle, weight: nil, size: size)
        }
        return resolved(
            family: family,
            style: runtime.resolvedCodeFontStyle,
            weight: runtime.resolvedCodeFontWeight,
            size: size
        )
    }

    /// The face the bundled family is drawn at when nothing else is chosen.
    private static let bundledStyle = "SemiLight"

    @MainActor
    private static var configuredFamily: String? {
        GhosttyRuntime.shared.resolvedCodeFontFamily
            ?? (BundledFonts.isCodeAvailable ? BundledFonts.code : nil)
    }

    /// A face within `family`, chosen by style name and weight.
    ///
    /// Neither goes through SwiftUI's `.weight()`, which asks for a weight
    /// *trait*: on a variable font that trait resolves every weight back to
    /// the regular face, so the request is silently ignored. A named instance
    /// is reached by its face name, and an unnamed weight by setting the
    /// `wght` variation axis. A style the family does not have falls back to
    /// its regular face rather than failing.
    ///
    /// A named style wins over a weight, since it names the face outright
    /// while the axis only asks for one — setting both leaves the axis to
    /// override the very face that was asked for.
    @MainActor
    private static func resolved(
        family: String,
        style: String?,
        weight: Font.Weight?,
        size: CGFloat
    ) -> Font {
        guard style != nil || weight != nil else {
            return .custom(family, size: size)
        }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: family]
        if let style {
            attributes[.face] = style
        } else if let weight {
            attributes[.variation] = [weightAxis: variationValue(for: weight)]
        }
        let descriptor = NSFontDescriptor(fontAttributes: attributes)
        guard let match = NSFont(descriptor: descriptor, size: size) else {
            return .custom(family, size: size)
        }
        return .custom(match.fontName, size: size)
    }

    /// The OpenType `wght` axis tag, as the four-character code CoreText wants.
    private static let weightAxis = 0x77676874

    /// `Font.Weight` carries no numeric value, so the CSS scale the axis uses
    /// is restated here.
    private static func variationValue(for weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight: 200
        case .thin: 100
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}

extension NSFont {
    /// The composer's body font, for its text storage.
    ///
    /// The system face rather than the bundled serif: what the user is typing
    /// should read as input, not as published prose. `MarkdownComposerStyler`
    /// derives bold and italic from this descriptor.
    static func composerBody(ofSize size: CGFloat) -> NSFont {
        .systemFont(ofSize: size)
    }
}
