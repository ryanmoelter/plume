import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The files a `SendUserFile` call handed the user: its caption, then each
/// image drawn inline and every other file as a card that opens it.
struct SentFilesView: View, ThemedView {
    @Environment(\.theme) var theme

    let sent: SentUserFiles

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = sent.caption {
                Label {
                    Text(caption)
                } icon: {
                    Image(systemName: "paperclip")
                }
                .font(typography.body.font)
                .emphasis(.secondary)
            }
            images
            ForEach(sent.cards, id: \.self) { SentFileCard(file: $0) }
        }
        .padding(.vertical, dimensions.messageBlockSpacing / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listItemPadding(vertical: false)
    }

    /// One image takes the column; several share it two to a row, so a batch
    /// of screenshots doesn't run for screens.
    @ViewBuilder
    private var images: some View {
        let images = sent.inlineImages
        if images.count == 1 {
            SentFileImage(file: images[0], maxHeight: 320)
        } else if !images.isEmpty {
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: images.count, by: 2)), id: \.self) { start in
                    GridRow {
                        SentFileImage(file: images[start], maxHeight: 200)
                        if start + 1 < images.count {
                            SentFileImage(file: images[start + 1], maxHeight: 200)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }
}

/// A sent image, decoded off the main actor. A file gone from disk falls back
/// to its card, which says so.
private struct SentFileImage: View, ThemedView {
    @Environment(\.theme) var theme

    let file: URL
    let maxHeight: CGFloat

    @State private var loaded: SentFileImageCache.Entry?

    var body: some View {
        Group {
            switch loaded ?? SentFileImageCache.cached(file) {
            case .image(let image)?:
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(colors.divider, lineWidth: 1)
                    }
                    .contentShape(.rect)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
                    .onTapGesture { SentFileActions.open(file) }
                    .help("Open \(file.lastPathComponent)")
                    .contextMenu { SentFileActions.menu(for: file) }
                    .plumeID(
                        AccessibilityID.sentFileImage,
                        label: file.lastPathComponent,
                        value: file.path,
                        invoke: { SentFileActions.open(file) }
                    )
            case .unreadable?:
                SentFileCard(file: file)
            case nil:
                RoundedRectangle(cornerRadius: 8)
                    .fill(colors.surfaceTint)
                    .frame(maxWidth: .infinity)
                    .frame(height: min(maxHeight, 120))
            }
        }
        .task(id: file) {
            guard SentFileImageCache.cached(file) == nil else { return }
            loaded = await SentFileImageCache.load(file)
        }
    }
}

/// A sent file as a button that opens it, with a second that shows it in
/// Finder.
private struct SentFileCard: View, ThemedView {
    @Environment(\.theme) var theme

    let file: URL

    @State private var facts: SentFileFacts?
    @State private var isHovering = false

    /// Unknown until the stat lands; a card is enabled meanwhile, since the
    /// open is a no-op on a missing file anyway.
    private var isMissing: Bool { facts?.exists == false }

    var body: some View {
        HStack(spacing: 10) {
            Button { SentFileActions.open(file) } label: {
                HStack(spacing: 10) {
                    Image(nsImage: SentFileActions.icon(for: file))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.lastPathComponent)
                            .font(typography.body.font)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Rendered while empty too, so the card keeps its
                        // height when the stat lands.
                        Text(subtitle)
                            .font(typography.caption.font)
                            .emphasis(.subtle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .plumeID(
                AccessibilityID.sentFileCard,
                label: file.lastPathComponent,
                value: file.path,
                invoke: { SentFileActions.open(file) }
            )
            .disabled(isMissing)

            Button { SentFileActions.reveal(file) } label: {
                Image(systemName: "folder")
                    .foregroundStyle(colors.selection)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .plumeID(
                AccessibilityID.sentFileReveal,
                label: file.lastPathComponent,
                invoke: { SentFileActions.reveal(file) }
            )
            .disabled(isMissing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 420, alignment: .leading)
        .background(isHovering && !isMissing ? colors.surfaceTint : .clear, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(colors.divider, lineWidth: 1)
        }
        .plumeHover { isHovering = $0 }
        .help(file.path)
        .contextMenu { SentFileActions.menu(for: file) }
        .task(id: file) {
            facts = await SentFileFacts.read(file)
        }
    }

    private var subtitle: String {
        guard let facts else { return " " }
        guard facts.exists else { return "No longer on disk" }
        let folder = (file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        guard let size = facts.size else { return folder }
        return "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(folder)"
    }
}

private nonisolated struct SentFileFacts: Equatable {
    let exists: Bool
    let size: Int64?

    static func read(_ file: URL) async -> SentFileFacts {
        await Task.detached(priority: .userInitiated) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
                return SentFileFacts(exists: false, size: nil)
            }
            return SentFileFacts(exists: true, size: (attributes[.size] as? NSNumber)?.int64Value)
        }.value
    }
}

@MainActor
private enum SentFileActions {
    /// Off the main actor: `NSWorkspace` blocks while Launch Services starts
    /// the handler.
    static func open(_ file: URL) {
        Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            NSWorkspace.shared.open(file)
        }
    }

    static func reveal(_ file: URL) {
        ChatLinkOpener.open(.file(file))
    }

    /// The icon for the file's type rather than the file itself, which would
    /// read the disk from `body`.
    static func icon(for file: URL) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: file.pathExtension) ?? .data)
    }

    @ViewBuilder
    static func menu(for file: URL) -> some View {
        Button("Open") { open(file) }
        Button("Show in Finder") { reveal(file) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
    }
}

/// Sent images, downsampled and kept across remounts so a row scrolled back
/// into view draws at once rather than growing from its placeholder again.
@MainActor
enum SentFileImageCache {
    enum Entry {
        case image(NSImage)
        case unreadable
    }

    private static let limit = 24
    /// Twice the widest the chat column draws an image, for a Retina screen.
    private nonisolated static let maxPixelSize = 1600

    private static var cache: [URL: Entry] = [:]

    static func cached(_ file: URL) -> Entry? {
        cache[file]
    }

    static func load(_ file: URL) async -> Entry {
        let image = await Task.detached(priority: .userInitiated) { downsampled(file) }.value
        let entry: Entry = image.map { .image($0) } ?? .unreadable
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[file] = entry
        return entry
    }

    private nonisolated static func downsampled(_ file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Points at 2x, so a Retina capture draws at the size it was taken.
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
