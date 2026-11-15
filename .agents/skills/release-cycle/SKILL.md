---
name: release-cycle
description: "Coordinate Plume’s queued Linear work into a reviewed release, with parallel packages, isolated worktrees, verification, and explicit release gates."
---

# release-cycle

## Shared workflow

Read [the canonical workflow](../../../.claude/skills/release-cycle/SKILL.md) in full before acting. Follow its steps, domain rules, and approval gates. The Codex adaptations below replace only host-specific instructions. Resolve repository-relative paths from the checkout root.

## Codex host adaptations

Read only the Codex host adaptations in [implement](../implement/SKILL.md) before delegating; do not load its canonical workflow. Its model roles, independent-review fallback, worktree lifecycle, checkout boundary, and tool substitutions apply here too. This workflow explicitly authorizes delegation. Create separate Codex worktrees for packages before spawning agents; select their base deliberately. Use codex/ as the default prefix.

Only the coordinator updates Linear. Do not classify failing tests as environmental merely because the source lists them: confirm the failure and its documented environmental prerequisite in CONTRIBUTING.md, and report exact output. Keep all required verification and user review.

Replace the Claude Artifact/artifact-design review-page step with a local review document containing one section per package, checklists, and captioned media links. Use a connected publishing tool only if available and authorized. Update the same document as packages land and show its link to the user. Do not drop the review surface because Artifact is unavailable.

Use collaboration completion notifications and bounded wait_agent calls to follow agents. Keep foreground build/test execution. A test chat's Haiku setting refers to Claude inside Plume, not the coordinating Codex model.

Run the release from the assigned checkout. Never cross the worktree boundary to use the primary checkout: coordinate a handoff when the release scripts require it. Preserve plan approval, changelog Draft approval, main-merge confirmation, signing checks, outward-facing publication/tap approval, beta branch restrictions, and the prohibition on installing. The source's cleanup commands do not authorize forced removal of active or unfinished worktrees; use Codex archive_worktree only after confirming ownership and completed work.
