---
name: release-beta
description: "Ship a reviewed Plume beta from an active release cycle, preserving changelog approval, main merge, signing, and publication gates."
---

# release-beta

## Shared workflow

Read [the canonical workflow](../../../.claude/skills/release-beta/SKILL.md) in full before acting. Follow its steps, domain rules, and approval gates. The Codex adaptations below replace only host-specific instructions. Resolve repository-relative paths from the checkout root.

## Codex host adaptations

Delegate builds and tests with collaboration.spawn_agent to a fast available Codex model in place of Sonnet. Follow completion through bounded wait_agent calls. Give each agent the assigned checkout path and foreground verification requirement. Use the available Linear tool schemas for roadmap changes. Where the beta workflow references release-cycle for changelog or bundle verification, read only the named section of its canonical source; do not load the whole release-cycle or implement workflows.

Operate only in the assigned checkout. Hand primary-checkout operations to its coordinator when necessary. Preserve every source approval gate, including the changelog edit, pushing main and tags, publishing the release, and publishing the feed. A beta request authorizes its described merge into main; it does not waive separate publication gates. Never pass --allow-branch without explicit maintainer approval. Keep testing follow-ups open, do not bump Homebrew, and continue the release cycle after the beta.
