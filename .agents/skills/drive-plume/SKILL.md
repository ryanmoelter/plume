---
name: drive-plume
description: "Drive and inspect a running Plume debug build through its control socket. Use for UI verification, reproduction, screenshots, and recordings without stealing focus."
---

# drive-plume

## Shared workflow

Read [the canonical workflow](../../../.claude/skills/drive-plume/SKILL.md) in full before acting. Follow its steps, domain rules, and approval gates. The Codex adaptations below replace only host-specific instructions. Resolve repository-relative paths from the checkout root.

## Codex host adaptations

Use the repository's control client directly. Claude environment variables and Claude permission-file cautions in the source refer to the application under test; keep them. Launch a scratch instance with its own PLUME_APP_SUPPORT and socket. Read back state after actions, preserve --assert-frontmost, and stop only the captured PID.

Delegate screenshot capture and inspection to a Codex subagent. Give it the absolute checkout boundary and explicitly request the capture. Use local image/video links in the reply. Do not take screenshots in the main conversation without the user's permission.
