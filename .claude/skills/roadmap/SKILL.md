---
name: roadmap
description: Read and change Plume's roadmap, which lives in Linear. Use for "what should I work on", "what's next", "what's in the queue", to record that an item shipped, to add an item, or to reprioritize the queue.
---

# Roadmap

The roadmap is Linear, team `Plume`. Projects are organized by use case. Route an issue by its primary user outcome, not by the UI component or code area it touches:

- **Multitask** — Home, the sidebar, agent status, notifications, unread state, tabs and splits, terminal history, worktrees and directories, workstream coloring, cross-conversation search.
- **Core chat** — the composer, message rendering, selection and copy, conversation controls, history and transcript continuity, remote-session reconnection, model and effort controls, Claude Code mods, cross-session messaging.
- **Understand context** — the info pane, reference chips, session metadata, quotas, statusline customization, goal status, issue/PR/MR references, live app previews, the `/mcp` flow.
- **Review** — PR visibility, checks, stacks, diffs, reviewing agent output, review-specific visualization.
- **Tools for agents** — user-facing `plume` commands and capabilities agents invoke, including bundled Plume skills.
- **Test on devices** — Android devices and emulators, iOS Simulator, remote devices, embedded device views, streaming, device-specific split workflows.
- **Get started** — setup, permissions, onboarding, imports and migration.
- **Codex support** — Codex-specific compatibility and missing capabilities.
- **Delight** — palettes and visual polish that make Plume feel better to use.
- **Infrastructure** — shared engineering foundations, process and socket plumbing, testing, window-resize performance, titlebar theming.
- **Integrations** — authentication, external-provider support, sync, connector configuration.
- **Admin** — releases, documentation, operational and non-code work.
- **Code architecture visualizer** — its own project.
- **Later** — explicitly deferred work, including driving other apps through a pluggable desktop-control backend.

When an issue could fit two projects:

- Device work goes in Test on devices, even when an agent invokes it through the CLI.
- Codex support holds only Codex-specific gaps. A general improvement found through Codex goes in its outcome project.
- User-facing reference chips go in Understand context, not Integrations.
- The command an agent invokes goes in Tools for agents. The shared plumbing under it goes in Infrastructure.

Six projects are retired and Completed: Agent & session, Terminals, tabs & window, Sidebar & tasks, Composer & statusline, Chat rendering & interaction, and Requests. Never put an issue in one. Older Done history still lives there, so a search can still return them.

**To do** means queued. **Backlog** means wanted but not queued. **In Progress** means an agent is working on it. **In Review** means it is merged into a release branch and waiting for the user's approval. **Done** and **Canceled** mean what they say.

Status names get renamed, so filter on the state *type* when reading: `unstarted` is To do, `backlog` is Backlog. A name that matches nothing returns an empty list, not an error.

`estimate` is the size: 1 = XS, 2 = S, 3 = M, 5 = L, 8 = XL. Unset means nobody has sized it. Those are the only values the scale accepts — anything else snaps to the nearest.

Labels:

- `Requested` means someone outside this repo asked for the item. It records provenance only, so choose the project by outcome as usual.
- `Needs decision` means the decision in the description must be settled first.
- `Bug` marks a defect.
- The `Project snapshot · 2026-11-02` group records each issue's project before the migration. Leave it on existing issues, and never apply it to a new one.

An issue states the item and any real blocker. It does not describe what the code already does — read the code for that.

## What should I work on

Call `list_issues` with `team: "Plume"`, `state: "unstarted"`, and `fields: ["id", "title", "priority", "estimate", "project", "description"]`.

Sort by `priority` ascending. Priority is the queue order.

Report a numbered list: identifier, title, size, project. Read the whole description before starting anything.

## Record that an item shipped

`save_issue` with the identifier and `state: "Done"`. Nothing else.

Do not write a summary of what shipped into the issue. The commit is the record — this is what stops Linear regrowing the history the roadmap accumulated.

If the work only partly landed, leave the issue open and add a `save_comment` saying what is left.

## Add an item

`save_issue` with `team: "Plume"`, the `project` for its outcome, `state: "Backlog"`, and a description holding the item and any real blocker. If the item came from outside this repo, add the `Requested` label.

Do not inventory the codebase in the description. Ask the user for a size; leave `estimate` unset rather than guessing.

## Reprioritize

Into the queue: `state: "To do"` plus a `priority`. Out of it: `state: "Backlog"` and `priority: 0`.

Reordering means changing `priority`. Never record an order in the description — priority already holds it.

## Present it back

Group by project and name the identifier, so the reader can open it. Say the title and the size; offer the detail rather than pasting a whole description into chat.
