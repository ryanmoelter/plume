---
name: release-cycle
description: Turn the roadmap's Up Next queue into a shipped local release. Coordinator stays small; parallel worktree agents implement; merge to a release branch, debug-build for manual evaluation, iterate, then release per docs/releasing.md.
---

# Release cycle

Run this when the user says "make the next release" or asks to work through the roadmap queue. You are the **coordinator**. Keep your own context small: read only the roadmap, `docs/releasing.md`, and agent reports. Delegate every implementation, build, and verification to subagents.

## Inputs

- Optional: extra roadmap items beyond Up Next. Recommend two or three cheap, high-value ones from other sections and ask which to include. Always ask about any Up Next item the roadmap marks as blocked on a decision.
- Target version. Default: bump the minor for a feature release, the patch for fixes only.

## 1. Plan the packages

Read `docs/roadmap.md`. Group the queued items into work packages so that **no two packages edit the same files**. The roadmap names the files for each item; cluster by those.

- S-only groups go to **Sonnet**; anything M or L, or anything touching the headless wire protocol, goes to **Opus**. Always set `model` explicitly.
- Cross-cutting passes (accessibility identifiers, a styling sweep) touch every view. Run them **after** the merge, on the release branch, not in parallel.
- Note the seams where packages share a file anyway (`ChatTabView`, `ChatComposer` are the usual ones) and tell each agent which other agents are in that file so they keep their footprint minimal.

Write the package table into the plan file before launching anything.

## 2. Launch implementers

One `Agent` call per package, all in one message, with `isolation: "worktree"` and the chosen `model`. Each prompt carries the package description plus the rule block below verbatim.

```
You are running inside a dedicated git worktree of <repo root>. First run `pwd` to learn your
worktree root. HARD BOUNDARY: every file you read, edit, build, or run a command against must live
under that root. Never cd out of it, never touch the parent repo or sibling worktrees.

Read CLAUDE.md at your worktree root first and follow it. Read the roadmap section(s) for your items.

- Create a branch: `git checkout -b ryanm/<slug>`. Commit on it (signing works normally), early and often.
- NEVER run `git stash`. The stash ref is shared by every worktree, so a concurrent agent's pop takes your
  entry and you get theirs. Use `git worktree`-local means instead: commit a WIP, or copy files aside.
- Verify with `xcodebuild -scheme Plume -destination 'platform=macOS' build` and
  `xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests`.
  Confirm test names scroll past. Two suites fail in ANY worktree for environmental reasons:
  `SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` and `SurfaceCommandTests`.
  Report those as environmental; anything else is yours to fix. Add tests for pure logic.
- Roadmap: check off shipped items in the item's own **section only** and add a short "what shipped"
  note there. Do NOT edit the "Up Next" list at the top; the coordinator prunes it.
- Comments: terse, why-only, per CLAUDE.md. No changelog-style comments.
- `distress-call "<question>" "<context>"` for decisions only the user can make (blocks; exit 3 =
  dismissed, decide and state the assumption). `papercut add "<title>" "<expected vs got>"` for
  friction; keep going.
- Do not take screenshots.

Report back: branch name, worktree absolute path, commit SHAs, a one-paragraph summary, test
results, and anything left unverified.
```

Do not poll. Completion notifications arrive on their own. Use the wait to write or refine this skill and the plan.

## 3. Merge to a release branch

```
git checkout -b ryanm/release-<version> main
git merge --no-ff ryanm/<slug>     # smallest package first, largest last
```

If an agent used the auto-generated `worktree-agent-*` branch instead of creating `ryanm/<slug>`, merge that branch by name; the worktree list shows which is which. A trivial conflict you resolve yourself. A non-trivial one goes to a Sonnet agent with both sides and the two package summaries. Build after the last merge before moving on.

Then run the cross-cutting packages (step 1). **An `isolation: "worktree"` agent forks from `main`, not from your current branch**, so tell it to start with `git checkout -B ryanm/<slug> ryanm/release-<version>` before editing (a plain `git checkout ryanm/release-<version>` fails because the primary checkout already has that branch out), or its annotations land on stale files and every shared file conflicts. Merge it the same way.

Prune the Up Next list in `docs/roadmap.md`: remove shipped lines, renumber, keep the deferred and not-queued paragraphs. Commit.

## 4. Debug build for manual evaluation

Delegate to a Sonnet verifier, on the release branch in the primary checkout:

- Debug build, then `PlumeTests`. Report failures verbatim.
- Launch the built `Plume.app` from DerivedData (`-showBuildSettings | awk '$1 == "BUILT_PRODUCTS_DIR"'`). Debug writes to `Plume.debug/`, so it runs beside the installed app.
- Walk the process tree from Plume's own PID and read the unified log for errors. Never `pgrep -x Plume` or global-grep `claude`.

Tell the user the app is running and give a per-package checklist of what to try. Each round of feedback becomes targeted agents on the release branch (Sonnet for tweaks, Opus for behavior bugs), then rebuild and relaunch through the verifier.

## 5. Release

Only after the user approves. Follow `docs/releasing.md`; do not duplicate it here.

- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the **app target's** Debug and Release blocks only. Commit on the release branch.
- Merge the release branch into `main` (`--no-ff`).
- Quit any running Plume, then delegate steps 2 and 3 of `docs/releasing.md` to Sonnet: Release build, tests, copy to `/Applications`, PlistBuddy, codesign, otool, process-tree check.
- Tag `v<version>` on the bump commit and push `main` with the tag.
- `git worktree remove` each agent worktree, `git worktree prune`, delete merged `ryanm/*` branches.

## Gotchas

- `git stash` is shared across worktrees. In the first run, three agents stashed to measure a test baseline and popped each other's work; one recovered from `git fsck --unreachable`. The rule block now forbids it. If it happens anyway, `git stash list` labels usually say whose work an entry holds; restore with `git checkout <stash> -- <paths>`.

- `-only-testing` with a name matching nothing prints `** TEST SUCCEEDED **` having run nothing. Confirm names scrolled past.
- Overwriting a running `/Applications/Plume.app` corrupts the process. Quit first.
- A schema change meets the installed store for the first time on the release launch. Watch the log for a `Plume.store.<timestamp>.bak` move.
- Roadmap edits: agents own their sections, the coordinator owns Up Next. Both editing Up Next is a guaranteed conflict.
- Six parallel `xcodebuild`s are slow but each worktree gets its own DerivedData. Do not try to share one.
