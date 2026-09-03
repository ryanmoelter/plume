# Overnight run state

Working notes for the unattended pass over the roadmap's **Testing results**.
Delete this file before the branch is merged.

## Where things are

- Plan: `~/.claude/plans/let-s-implement-the-items-wiggly-kahan.md` — **read it first**, it has the full per-item approach, the settled design decisions, and the rules for the run.
- Worktree: `/Users/ryanmoelter/Development/Plume/.worktrees/testing-fixes`, branch `ryanm/testing-fixes`.
- Rebased onto **local** `main` (`0a8e49b`), which is 3 commits ahead of `origin/main`. `wt cob` branched from origin, so this was corrected by hand. Don't re-rebase onto origin.

## Baseline, established before any edit

- `xcodebuild -scheme Plume -destination 'platform=macOS' build` — **BUILD SUCCEEDED**.
- `xcodebuild ... test -only-testing:PlumeTests` — exit 0, **557 tests, zero failures**.
- Both suites the plan expected to fail environmentally passed here: `SurfaceCommandTests` (a real GUI session is available) and `SessionJSONLReaderTests`. An earlier `** TEST FAILED **` was a flake.
- **Any failure from this point is a regression, not the environment.**

## Decisions already settled (do not re-ask, Ryan is asleep)

- **Permission mode default:** a Plume setting whose default value is "follow Claude Code", resolved from `~/.claude/settings.json`.
- **Composer:** two rows. Top row the text area alone, full width. Bottom row controls (permission mode, model, effort) left, send button right. A first cut to be tweaked awake — don't over-invest in styling.
- **Question options:** keep the question area's tint; options become outline-only with a blue border, no grey fill.
- **On trouble:** best judgment, land it, flag it in the summary. Never block, never stop the run.
- **Do not merge.** Everything stays on the branch; leave the worktree in place.
- **No screenshots** — this machine has no Screen Recording permission. Never claim a visual result.

## Item status

| # | Item | Status |
|---|---|---|
| 1 | Chat scrolling | landed — `5967676` |
| 2 | Permission mode | landed — `b5092b9` |
| 3 | Untrusted directory | landed — `2097318` |
| 4 | Inline-code thin spaces | landed — `64c15c7` |
| 5 | Composer keyboard (5 fixes) | landed — `35c72fa`, `26252fd`, `34ba7c3` |
| 6 | Worktree WIP markers | landed — `e709a9e` |
| 7 | TabRenderMode removal | in progress |
| 8 | Terminal hint | not started |
| 9 | Statusline | not started |
| 10 | Question rows | not started |
| 11 | Plan overlay | not started |

Order: 1–6 may run in parallel; 7 after them; 8, 9, 10 after 7; 11 after 8.
Re-read what 7 actually left behind before starting 8 and 9.

## Judgment calls made during the run

_(append here as they happen — this is what the final summary reports)_

- **Concurrent subagents share this one worktree.** Five agents edited source here at once, so a full test run can compile a half-written file belonging to another agent and report a failure that is not yours. Seen once on `ChatScrollGrowthTests`: `** TEST FAILED **` with no error line, then a clean pass moments later on identical code. Re-run before believing a failure.
- **Every commit tonight is unsigned.** 1Password is locked, so commits use `--no-gpg-sign`. Re-sign before merging if that matters.
- **Commit boundaries got crossed once.** Item 2's agent staged broadly while item 3's `AgentLauncher.swift` edit sat uncommitted in the same tree, so `b5092b9` absorbed part of item 3's work. Nothing was lost and the code is correct, but `b5092b9` and `2097318` are not cleanly separable by item. After this the run stopped fanning out over shared files and went serial.
- **Item 5 arrived pre-committed as `1dc3b1a`, a single commit with a prose body — something else in this environment committed my working-tree changes before I ran `git commit` myself.** The instructions asked for separate commits per fix, and the commit had no `Co-Authored-By` trailer, so I soft-reset it and re-split into `35c72fa` (⌘↩), `26252fd` (caret placement, recognized-command styling, and queue recall — these three share enough plumbing in `MarkdownComposerTextView`/`Coordinator` that splitting further risked broken intermediate diffs), and `34ba7c3` (autocomplete scroll-to-selection). Content is unchanged from what was committed; only the commit boundaries and messages differ.

