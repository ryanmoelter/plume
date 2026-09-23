import SwiftUI

/// Thumbnails of the images attached to the draft, above the text field.
struct ComposerAttachmentStrip: View, ThemedView {
    @Environment(\.theme) var theme

    let images: [ChatImage]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    thumbnail(image, at: index)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: Self.thumbnailSize)
    }

    private static let thumbnailSize: CGFloat = 52

    @ViewBuilder
    private func thumbnail(_ image: ChatImage, at index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let decoded = ChatImageCache.image(for: image) {
                    Image(nsImage: decoded)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .emphasis(.secondary)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(colors.divider, lineWidth: 1)
            }

            Button {
                onRemove(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(colors.foreground)
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Remove")
            .accessibilityLabel("Remove image")
        }
    }
}
