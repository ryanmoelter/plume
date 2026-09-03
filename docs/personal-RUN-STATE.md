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
| 1 | Chat scrolling | not started |
| 2 | Permission mode | not started |
| 3 | Untrusted directory | not started |
| 4 | Inline-code thin spaces | not started |
| 5 | Composer keyboard (5 fixes) | not started |
| 6 | Worktree WIP markers | not started |
| 7 | TabRenderMode removal | not started |
| 8 | Terminal hint | not started |
| 9 | Statusline | not started |
| 10 | Question rows | not started |
| 11 | Plan overlay | not started |

Order: 1–6 may run in parallel; 7 after them; 8, 9, 10 after 7; 11 after 8.
Re-read what 7 actually left behind before starting 8 and 9.

## Judgment calls made during the run

_(append here as they happen — this is what the final summary reports)_
