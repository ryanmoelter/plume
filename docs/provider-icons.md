# Provider icons

Plume uses the providers' own marks in the model picker:

- `ClaudeLogo` is the Claude starburst path embedded in the header wordmark on
  [claude.com](https://claude.com), retrieved September 13, 2026. The path is
  unchanged; only its view box and template fill adapt it to Plume's UI.
- `ChatGPTLogo` is OpenAI's monochrome Blossom from the official
  [OpenAI logo archive](https://cdn.openai.com/brand/OpenAI-Logos-2025.zip),
  linked from the [OpenAI design guidelines](https://openai.com/brand/). Its
  path is unchanged; only its view box and template fill adapt it to Plume's UI.

The marks remain the property of Anthropic and OpenAI respectively. Their use
in Plume identifies the corresponding provider and does not imply endorsement.

The model menu groups plain model rows under Claude and Codex section headers.
`ModelMenu` builds native AppKit menu items so it can explicitly set header
`preferredImageVisibility` to `.visible` on macOS 27, whose automatic menu-image
policy otherwise normally hides images. Both header assets are checked by
`ModelMenuTests`; model rows and More submenus deliberately have no image.
