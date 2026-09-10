---
name: roadmap
description: Read and change Plume's roadmap, which lives in Linear. Use for "what should I work on", "what's next", "what's in the queue", to record that an item shipped, to add an item, or to reprioritize the queue.
---

# Roadmap

The roadmap is Linear, team `Plume`. Seven projects hold every item:

- **Chat rendering & interaction** — the message list and everything drawn in it.
- **Composer & statusline** — the floating panel below the conversation.
- **Sidebar & tasks** — the task list and what a task is.
- **Terminals, tabs & window** — window chrome, the tab strip, shortcuts, terminal surfaces.
- **Agent & session** — what a running agent does and how it reports.
- **Requests** — asked for from outside this repo, none yet buildable.
- **Platform & tooling** — foundations and the tooling around them.

**Todo** means queued. **Backlog** means wanted but not queued. **In Progress**, **Done** and **Canceled** mean what they say.

`estimate` is the size: 2 = S, 3 = M, 5 = L, 8 = XL. Unset means nobody has sized it. Those are the only values the scale accepts — anything else snaps to the nearest.

Three labels carry state the queue cannot. `deferred` is wanted eventually. `blocked-on-decision` needs the decision in its description settled first. `needs-spec` needs a clarifying pass with whoever asked.

An issue states the item and any real blocker. It does not describe what the code already does — read the code for that.

## What should I work on

Call `list_issues` with `team: "Plume"`, `state: "Todo"`, and `fields: ["identifier", "title", "priority", "estimate", "project", "description"]`.

Sort by `priority` ascending, then by the `Queue position` line in each description. Priority buckets the queue; the position line is the exact order.

Report a numbered list: identifier, title, size, project. Read the whole description before starting anything.

## Record that an item shipped

`save_issue` with the identifier and `state: "Done"`. Nothing else.

Do not write a summary of what shipped into the issue. The commit is the record — this is what stops Linear regrowing the history the roadmap accumulated.

If the work only partly landed, leave the issue open and add a `save_comment` saying what is left.

## Add an item

`save_issue` with `team: "Plume"`, the `project` for its area, `state: "Backlog"`, and a description holding the item and any real blocker.

Do not inventory the codebase in the description. Ask the user for a size; leave `estimate` unset rather than guessing.

## Reprioritize

Into the queue: `state: "Todo"` plus a `priority`. Out of it: `state: "Backlog"` and `priority: 0`.

Reordering means rewriting the `Queue position: n of m` line on every affected issue. Use `patch` for that, never a full `description` — a full resend loses whatever else the description holds.

## Present it back

Group by project and name the identifier, so the reader can open it. Say the title and the size; offer the detail rather than pasting a whole description into chat.
