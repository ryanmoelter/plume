---
name: release-cycle
description: Turn the roadmap's Todo queue in Linear into a shipped local release. Coordinator stays small; parallel worktree agents implement; merge to a release branch, debug-build for manual evaluation, iterate, then release per docs/releasing.md.
---

# Release cycle

Run this when the user says "make the next release" or asks to work through the roadmap queue. You are the **coordinator**. Keep your own context small: read only the roadmap (through the `roadmap` skill), `docs/releasing.md`, and agent reports. Delegate every implementation, build, and verification to subagents.

## Inputs

- Optional: extra items beyond the Todo queue. Recommend two or three cheap, high-value Backlog issues — prefer small estimates — and ask which to include. Always ask about a `blocked-on-decision` issue before pulling it in — the decision in its description has to be settled first.
- Target version. Default: bump the minor for a feature release, the patch for fixes only.

## 1. Plan the packages

Invoke the `roadmap` skill to list the Todo queue, and read each issue's description. Group the queued issues into work packages so that **no two packages edit the same files**. An issue names files only where they matter, so read the code to find the real footprint before clustering.

- S-only groups (estimate 2) go to **Sonnet**; anything M or larger (estimate 3+), unsized, or touching the headless wire protocol, goes to **Opus**. Always set `model` explicitly.
- Cross-cutting passes (accessibility identifiers, a styling sweep) touch every view. Run them **after** the merge, on the release branch, not in parallel.
- Note the seams where packages share a file anyway (`ChatTabView`, `ChatComposer` are the usual ones) and tell each agent which other agents are in that file so they keep their footprint minimal.

Write the package table into the plan file before launching anything.

## 2. Launch implementers

One `Agent` call per package, all in one message, with `isolation: "worktree"` and the chosen `model`. Each prompt carries the package description plus the rule block below verbatim.

```
You are running inside a dedicated git worktree of <repo root>. First run `pwd` to learn your
worktree root. HARD BOUNDARY: every file you read, edit, build, or run a command against must live
under that root. Never cd out of it, never touch the parent repo or sibling worktrees.

Read CLAUDE.md at your worktree root first and follow it. Your assigned Linear issues state the items; read each one, then read the code before planning.

- Create a branch: `git checkout -b ryanm/<slug>`. Commit on it (signing works normally), early and often.
- NEVER run `git stash`. The stash ref is shared by every worktree, so a concurrent agent's pop takes your
  entry and you get theirs. Use `git worktree`-local means instead: commit a WIP, or copy files aside.
- Verify with `xcodebuild -scheme Plume -destination 'platform=macOS' build` and
  `xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests`.
  Confirm test names scroll past. Two suites fail in ANY worktree for environmental reasons:
  `SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` and `SurfaceCommandTests`.
  Report those as environmental; anything else is yours to fix. Add tests for pure logic.
- Roadmap: do NOT touch Linear. Report which issue identifiers you completed; the coordinator moves
  them to Done after the merge.
- Comments: terse, why-only, per CLAUDE.md. No changelog-style comments.
- `distress-call "<question>" "<context>"` for decisions only the user can make (blocks; exit 3 =
  dismissed, decide and state the assumption). `papercut add "<title>" "<expected vs got>"` for
  friction; keep going.
- Do not take screenshots. (Only one agent may screenshot at a time on this machine; the coordinator runs any visual check as a single serial pass after the merge.)

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

Move every shipped issue to Done through the `roadmap` skill.

### Clean up as each package lands

Remove a package's worktree and branch as soon as its work is on the release branch, rather than saving it all for after the release. A dozen stale worktrees make `git worktree list` useless for seeing what is still live, and every one of them holds a full DerivedData-adjacent checkout.

```
git worktree unlock <path>    # agent worktrees are created locked
git worktree remove --force <path>
git worktree prune
git branch -D ryanm/<slug> worktree-agent-<id>
```

**`git branch --merged` is the check, but it answers about commits, not content.** A branch whose work reached the release branch by cherry-pick or by a re-signing rebase reads as *unmerged*, because its original SHAs are not ancestors. Confirm with `git diff <branch>..HEAD --stat` instead — an empty diff means the content landed and the branch is safe to delete.

**Keep the worktree of any package whose work is not finished**, even if some of it merged. A package that was partly cherry-picked still holds the dropped commits, and they are the starting point for the follow-up agent.

## 4. Debug build for manual evaluation

Delegate to a Sonnet verifier, on the release branch in the primary checkout:

- Debug build, then `PlumeTests`. Report failures verbatim.
- Launch the built `Plume.app` from DerivedData (`-showBuildSettings | awk '$1 == "BUILT_PRODUCTS_DIR"'`). Debug writes to `Plume.debug/`, so it runs beside the installed app.
- **Launch it with `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE`.** The app inherits the shell that started it and passes that to every terminal tab it spawns, so launching from an agent's shell leaves each tab's `claude` reading itself as a nested session and skipping its transcript — the chat UI then shows nothing.
- Walk the process tree from Plume's own PID and read the unified log for errors. Never `pgrep -x Plume` or global-grep `claude`.

Tell the user the app is running and give a per-package checklist of what to try. Each round of feedback becomes targeted agents on the release branch (Sonnet for tweaks, Opus for behavior bugs), then rebuild and relaunch through the verifier.

## 5. Release

Only after the user approves. Follow `docs/releasing.md`; do not duplicate it here.

- **Draft the release notes as an unreleasable section.** Write a new top section in `CHANGELOG.md` headed `## Draft: <version> (<build>)`. That section becomes the GitHub release body, and it appears in every update window from then on, so the user reviews and finishes it by hand. `package-release.sh` refuses to package while the top heading says `Draft:`.
  - Draft from what shipped: this cycle's Done issues, plus `git log <last-tag>..HEAD --no-merges --format='%s'` for work that had no issue.
  - Match the existing sections' voice. Use user-facing bullets that lead with the change ("Send images in chat", "Fix …"), with sub-bullets for detail. Leave out internal work (refactors, test-only changes, tooling) unless a user would notice it.
  - Leave the draft **uncommitted**, so no draft ever reaches the history.
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the **app target's** Debug and Release blocks only, to the numbers in the draft heading. Commit the bump alone (`git add Plume.xcodeproj/project.pbxproj`), leaving `CHANGELOG.md` out of the commit.
- Tell the user the draft is ready for review, and wait. They edit the section and remove `Draft: ` from the heading to approve it. Then confirm the top heading is exactly `## <version> (<build>)`, and commit `CHANGELOG.md` on its own.
- Merge the release branch into `main` (`--no-ff`).
- Delegate the Release build and tests to Sonnet, telling it **not** to install — `xcodebuild -configuration Release clean build`, then `PlumeTests`, then verify the built bundle in `BUILT_PRODUCTS_DIR` (PlistBuddy, codesign, otool) rather than the installed one.
- **Check whether you are running inside the installed Plume before installing anything.** `echo $PLUME` says you are in *a* Plume; walking your own ancestry (`ps -o ppid=` up the chain) says *which*. If it is `/Applications/Plume.app`, that bundle is the one about to be replaced — the next bullet covers what that means. Tell the user what you found before running the install, so a surprise restart is not a surprise.
- **The install may be blocked by the permission classifier**, since it quits an app and writes into `/Applications`. Do not work around that. Say what you were trying to run and hand the user the command; they can approve it or run it themselves.
- Install with `scripts/install-release.sh`. It quits the installed app, replaces the bundle, verifies it, and logs everything to `/tmp/plume-install.log`. With `PLUME` set it re-execs detached so it survives the app it is replacing, and reopens the app afterwards so the session comes back; run from anywhere else it leaves the app closed for you to open.
- **A session hosted inside Plume survives the install.** The app reopens, restores the session, and you resume with your context intact — so carry on afterwards rather than treating the install as the end of the run. The install itself returns no output, so read `/tmp/plume-install.log` once you are back, then confirm the version in `/Applications/Plume.app/Contents/Info.plist` and that your own ancestry points at the relaunched PID.
- Do the tag and push **before** the install anyway. The resume is reliable but the install is the one step that replaces the app underneath you, so land anything you would hate to redo first.
- **Check every commit is signed before anything is pushed:** `git log --format='%G? %h %s' <last-tag>..main | grep -v '^G'` must print nothing. Agents fall back to `--no-gpg-sign` when 1Password locks mid-run, and re-signing after the fact means rewriting every later commit and force-pushing the tag. Re-sign the offenders first (`git rebase --force-rebase --rebase-merges <base>` recreates and signs everything; resolve replayed conflicts by taking the file from the original merge commit).
- Tag `v<version>` on the bump commit and push `main` with the tag.
- Clean up anything step 3 left: `git worktree list` and `git branch --list 'ryanm/*'` should hold nothing from this cycle.

## Gotchas

- `git stash` is shared across worktrees. In the first run, three agents stashed to measure a test baseline and popped each other's work; one recovered from `git fsck --unreachable`. The rule block now forbids it. If it happens anyway, `git stash list` labels usually say whose work an entry holds; restore with `git checkout <stash> -- <paths>`.

- `-only-testing` with a name matching nothing prints `** TEST SUCCEEDED **` having run nothing. Confirm names scrolled past.
- Overwriting a running `/Applications/Plume.app` corrupts the process. Quit first. `scripts/install-release.sh` waits for a real exit and aborts rather than replacing a live bundle, so prefer it over a bare `cp -R`.

- **Tell every agent to run its verification in the foreground.** Three agents in the 0.3.3 run handed a build or test to a background watcher and ended their turn waiting for a notification that never came — one of them left finished work uncommitted. They resume fine with a message saying to poll in the foreground instead, but it costs a round trip each time. Say it in the prompt.

- **A failed push is not a failed commit.** `git push` signs with the SSH agent, so a locked 1Password fails with `sign_and_send_pubkey: signing failed` and `Permission denied (publickey)`. There is no `--no-gpg-sign` equivalent — the only fix is unlocking, so ask. This is unrelated to the commit-signing fallback in CLAUDE.md, and the commits themselves may all be signed while the push still fails.
- A schema change meets the installed store for the first time on the release launch. Watch the log for a `Plume.store.<timestamp>.bak` move.
- Roadmap edits: only the coordinator writes to Linear. An issue is Done when its work is on the release branch, not when an agent's turn ends.
- The installed Plume runs `git status` on this repo on a timer, so a long rebase in the primary checkout can hit `index.lock: File exists`. `git rebase --continue` picks up where it stopped; quit Plume first for anything long.
- Six parallel `xcodebuild`s are slow but each worktree gets its own DerivedData. Do not try to share one.
