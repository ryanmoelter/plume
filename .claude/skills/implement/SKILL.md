---
name: implement
description: Implement one Plume roadmap item end to end — a Linear issue ID, a Linear URL, or a described task — in its own worktree, with fresh-agent code reviews, a debug build for the user's manual review, and then a hand-off to the release agent, a merge into main, or a PR. Use on "/implement PLUME-123", "work on PLUME-123", "implement this issue", or a task description meant to land as one change.
argument-hint: <PLUME-123 | linear URL | task description>
---

# Implement

Take one item from intake to landed. You are the **coordinator**: delegate exploring, implementing, building and reviewing to sub-agents, and keep your own context for decisions, commits, Linear and the user. The user's manual review is the one hard gate.

## 0. Intake

- If the argument is a `PLUME-<n>` identifier or a `linear.app/…/issue/PLUME-<n>…` URL, fetch the issue with `get_issue`, plus its comments and attachments. Read the code for what already exists; the issue states only the item.
- Otherwise the argument is the spec. Ask whether to create an issue for it; the answer is usually yes. On yes, create it through the `roadmap` skill in the project for its area, ask the user for a size, and carry on with the new identifier.
- State your understanding in one paragraph. Ask now only if the issue leaves a load-bearing choice open; otherwise start without a plan gate.
- Move the issue to In Progress through the `roadmap` skill. Record important decisions on the issue as comments when they are made.

## 1. Worktree

- Create the worktree through the `worktrees` skill: `wt cob <slug>-plume-<n> --no-tab`, then `EnterWorktree` with the path from `wt list`. `wt` branches off `main` and adds the `ryanm/` prefix.
- If the user names another base, such as the release branch, create the branch from it with `git branch` first, then `wt co <branch> --no-tab`.
- Every read, edit, build and command stays inside the worktree. The merge into `main` in step 6 is the only exception.

## 2. Implement

Delegate each step to a sub-agent. Set `model` explicitly: Sonnet for S-sized or mechanical work and for every build, test and launch; Opus for M or larger, unsized work, or anything touching the headless wire protocol.

Every sub-agent prompt carries:

- The worktree's absolute path, and the rule to confine all reads, edits and commands to it.
- Never run `git stash`; the stash stack is shared by every worktree.
- Run builds and tests in the foreground, never through a background watcher.
- Report any commit made with `--no-gpg-sign`.
- `distress-call` exists; use it rather than guess on a decision only the user can make.
- No screenshots unless the prompt asks for one.

Commit as you go, following the `commit-message` skill and the Commits section of `CLAUDE.md`, trailer included.

Verify through a Sonnet agent: `xcodebuild … build`, then `test -only-testing:PlumeTests`, confirming test names scroll past. `CLAUDE.md` lists the suites that fail for environmental reasons; anything else is yours to fix. Add tests for pure logic.

## 3. Review loop

Before the first debug build, review until clean:

1. Spawn a fresh Opus reviewer. Give it only the worktree path, the diff range (`main...HEAD`, or the base branch), and the issue's requirements — not your reasoning. It runs `/code-review` and reports findings. Never review inline.
2. Triage the findings yourself. Have a sub-agent fix the real ones, then re-test.
3. Spawn a *new* reviewer and repeat. Stop when a round finds nothing real. After three rounds, surface what is left to the user instead of looping.

## 4. Debug build and manual review

A Sonnet verifier builds and launches the worktree's own bundle:

- Find it with `-showBuildSettings | awk '$1 == "BUILT_PRODUCTS_DIR"'`, and launch with `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE open <app>`. Without the `env -u`, every agent tab's `claude` reads itself as nested and the chat shows nothing.
- Quit or relaunch only PIDs matching this bundle path (`pgrep -f "^<app>/Contents/MacOS/Plume"`). Other agents run their own builds.
- Confirm the launch with the `drive-plume` skill, then send `plume-notify "Ready to test" "PLUME-<n>"` (guarded per the user's notification rule).

Tell the user it is running and give a short checklist of what to try. Iterate on their feedback: a sub-agent edits, the verifier rebuilds and relaunches. Skip the review loop between iterations. Rebase onto `main` or the release branch when asked. If the user waives manual testing, note it and move on.

## 5. Final review

Once the user is happy, run one more fresh reviewer over the whole diff. Fix and re-test anything real; relaunch for a quick look if the fixes changed behavior.

## 6. Land

Only after the user approves. Check signatures first — `git log --format='%G? %h %s' <base>..HEAD | grep -v '^G'` must print nothing — and re-sign any offender while it is still one branch deep. Then take the first path that applies:

1. **PR, only when the user asks for one.** Use the `open-pr` skill. The issue stays In Progress.
2. **Release agent, if one is live.** Run `ListAgents` and look for a session named like `Release <version>`; ask if more than one could be it. Rebase onto its release branch if needed and re-test. Then `SendMessage` it a hand-off:
   - The issue identifier and title, and that the user approved it.
   - Branch, worktree path, commit SHAs, and the base it sits on.
   - Signing state, and verification results: build, tests, review rounds.
   - Known unrelated failures, verbatim.
   - Changelog bullets in the `CHANGELOG.md` voice.
   - "Leave PLUME-<n> open until it reaches `main`."

   Wait for its reply that the branch landed before cleaning up. The issue stays In Progress; the release agent moves it to Done.
3. **Otherwise, merge into `main`.** Rebase onto `main` and re-run the tests. Then, in the primary checkout, confirm it is on `main` and clean — if it is not, stop and ask, because another agent may own it. Run `git merge --no-ff -S <branch>`, push, and confirm `git rev-list --count main...origin/main` is 0. Mark the issue Done through `roadmap`; the user's approval of the merge is the confirmation.

## 7. Clean up

- `ExitWorktree` with `action: keep`, then `wt delete <name>`.
- Delete the branch once its content has landed: `git diff <branch>..<target> --stat` must be empty. A re-signed cherry-pick reads as unmerged to `git branch --merged`.
- Remove the worktree's debug data, `~/Library/Application Support/Plume.debug-<worktreeName>/`.
- Report what landed and where. For anything deferred, ask before creating an issue, and take its fields from the user.

## Gotchas

- Never `pkill Plume`, `pgrep -x Plume`, or global-grep for `claude`. Walk down from your own build's PID.
- A hidden chat tab reads as disabled and "not found" in `drive-plume`. Check which tab chip is selected before believing a reading.
- An `isolation: "worktree"` agent forks from `origin/main`, not your branch. Have it run `git checkout -B <branch-for-it> <your branch>` first, or have it work in your worktree instead.
