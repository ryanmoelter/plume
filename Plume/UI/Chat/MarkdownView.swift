import SwiftUI

/// Renders parsed markdown with a proportional font for prose — monospace is
/// reserved for code blocks and inline code, per the roadmap's "don't use a
/// monospace font" item. Block layout is plain SwiftUI stacks over
/// `MarkdownBlock.parse`; `MarkdownBlockView` draws each block.
///
/// The chat list does not use this: it places each block as its own lazy item
/// (`ChatPieceSplitter`). What is left needing a whole document at once is a
/// tool call's input and an injected line's body.
struct MarkdownView: View, ThemedView {
    @Environment(\.theme) var theme

    let blocks: [MarkdownBlock]
    /// Whether this is the agent speaking, which earns the serif. Anything
    /// else — the user's own message, a tool's output — stays in the system
    /// face so it reads as input rather than published prose.
    let isAgentVoice: Bool

    init(_ markdown: String, isAgentVoice: Bool = false) {
        self.blocks = MarkdownCache.blocks(for: markdown)
        self.isAgentVoice = isAgentVoice
    }

    init(blocks: [MarkdownBlock], isAgentVoice: Bool = false) {
        self.blocks = blocks
        self.isAgentVoice = isAgentVoice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Indexed rather than `Array(blocks.enumerated())`: the
            // enumerated array is a fresh value every pass, which SwiftUI
            // cannot match against the previous children, so it evicts and
            // rebuilds the whole subtree. A trace caught this rebuilding
            // markdown blocks ~31,000 times over 15 seconds of scrolling.
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], isAgentVoice: isAgentVoice)
                    .padding(.top, ChatBlockSpacing.markdownBlockTopInset(
                        blocks[index],
                        at: index,
                        dimensions: dimensions
                    ))
            }
        }
    }
}

#Preview("Tables") {
    ScrollView {
        MarkdownView(
            """
            | Item | Count | Cost |
            | :--- | :---: | ---: |
            | Widgets with a long descriptive name | 12 | $1.50 |
            | Gadgets | 3 | $22.00 |

            | | |
            |---|---|
            | Package | `libghostty-spm` |
            | Requirement | `.exact("1.5.0")` |

            | Syntax | Renders |
            | --- | --- |
            | `**bold**` | **bold** |
            | `a \\| b` | a \\| b |

            Prose containing a | pipe stays a paragraph.
            """,
            isAgentVoice: true
        )
        .padding()
    }
    .plumeTheme(bodySize: 16)
    .frame(width: 700, height: 620)
}
