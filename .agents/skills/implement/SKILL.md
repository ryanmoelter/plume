---
name: implement
description: "Implement one Plume issue or described change through isolated development, independent reviews, verification, user review, and authorized landing."
---

# implement

## Shared workflow

Read [the canonical workflow](../../../.claude/skills/implement/SKILL.md) in full before acting. Follow its steps, domain rules, and approval gates. The Codex adaptations below replace only host-specific instructions. Resolve repository-relative paths from the checkout root.

## Codex host adaptations

### Delegation and review

Use collaboration.spawn_agent, send_message, and list_agents in place of Agent, SendMessage, and ListAgents. Follow running agents with bounded wait_agent calls. Use a fast available Codex model for mechanical work, exploration, builds, tests, and driving; use a stronger available model for complex implementation and independent review. Sonnet and Opus in the source specify these roles, not literal Codex model IDs. Supply an explicit available model when the host permits it.

Keep every prompt's checkout boundary, no-stash rule, foreground verification, unsigned-commit report, and distress-call instructions. A fresh reviewer reads the diff and requirements independently; if no built-in code-review command exists, perform that same correctness review through the reviewer agent. Keep the three-round limit and final review.

### Worktrees and landing

Use Codex create_worktree instead of wt, EnterWorktree, and ExitWorktree. Discover list_artifacts for an existing suitable checkout first. Default branch prefix is codex/. Tell each agent its actual checkout path; Codex subagents share the filesystem and do not automatically receive an isolated worktree. Create any required isolation before dispatch and explicitly choose its base.

Do not leave the current worktree to merge or clean another checkout. If landing requires work in the primary checkout, hand it to a coordinator already assigned there or ask the user to perform that step. Use archive_worktree for Codex-managed worktrees only after confirming all work landed and all verification agents stopped. Do not run the source's raw wt deletion recipe.

Use available PR tooling only when the user requests a PR; read the applicable PR-description skill first. Release-agent discovery uses available Codex chat coordination tools for user-owned chats, or collaboration tools for live subagents. Never create a new chat unless the user asks. Obtain authorization before messaging a separate user-owned chat.

Use available build/test/drive skills, with the source's exact Plume xcodebuild commands as the repository-specific recipe. Claude launch environment cleanup remains necessary for Claude tabs in Plume.
