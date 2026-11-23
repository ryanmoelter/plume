---
name: plume-stack
description: Manage stacked branches and their PRs or MRs with Plume's `plume stack` command — create, split, track, navigate, restack, absorb fixes, submit, sync and undo. Use on "stack these changes", "restack", "submit the stack", and whenever a branch is or will be based on another feature branch rather than the trunk ("base this on X", "branch off X"), inside a Plume tab ($PLUME is set).
---

# Stacked branches with `plume stack`

`plume stack` records which branch each branch sits on. It uses that to restack children when a parent changes or squash-merges, and to point each PR at its parent. Run `plume stack help` first. It lists the commands, flags and resolved settings, and its output wins over anything here.

If `plume` is not on PATH, run `"$PLUME_CLI"` instead.

## Rules

- Use `plume stack` whenever a branch's base is another feature branch. Open its PR with `plume stack submit`, not `gh pr create --base <branch>` or `glab mr create --target-branch <branch>`. Those leave no stack record, so a later restack or sync can't follow the branch.
- Never rely on interactive pickers; they need a terminal. Pass a branch to `checkout`, and `<name>:<commit>` pairs to `split`. `track` and `untrack` default to the current branch and never prompt.
- Parse `plume stack list --json`: `{trunk, current, branches: [{name, parent, depth, current, needs_restack, behind_trunk, pr}]}`. `needs_restack` means a parent moved, so restack the branch. `behind_trunk` only means the root trails the trunk.
- Exit code 3 means a restack stopped on a rebase conflict. Resolve it, run `git rebase --continue`, then rerun the same `plume stack` command. It resumes where it stopped.
- `submit` and `sync` need `gh` for GitHub or `glab` for GitLab, installed and signed in. Every other command works offline, and `list --no-pr` skips the network.
- `submit` opens draft PRs titled with the branch's first commit subject and with empty bodies. Write real titles and descriptions afterwards. Pass `--ready` only if the user asked for ready PRs.
- If the stack's state is unclear, run `restack`, `submit` or `sync` with `--dry-run` first.
- Pass bare branch names. `create` and `split` add the branch prefix from Plume's Settings ▸ Projects themselves.
- `restack` refuses a dirty working tree, and `plume stack` never stashes. Commit first.
- To fix a commit lower in the stack, edit the file, `git add` the fix, and run `plume stack absorb`. It folds each staged hunk into the stack commit that last touched those lines and rebuilds the branches above. Check the "left staged" list it prints: those hunks had no clear target, so commit them yourself.
- If a `restack`, `sync`, `split`, `absorb` or `create --insert` left the stack wrong, run `plume stack undo`. Don't walk the reflog. `plume stack undo --list` lists older snapshots, and `plume stack undo <n>` restores one. Undo is local only, so re-push anything `sync --push` or `submit` already pushed.

## Common commands

| Goal | Command |
| --- | --- |
| See the stack and its PRs | `plume stack list` (`--all` for every stack) |
| New branch stacked on the current one | `plume stack create <name>` |
| Split a branch into a stack | `plume stack split <name>:<commit> [<name>:<commit> ...]` |
| Track existing branches | `plume stack track [<branch>] [--parent <p>]` |
| Move through the stack | `plume stack prev`, `next`, `first`, `last` or `checkout <branch>` |
| Rebase after changing a branch | `plume stack restack` (`--all` for the whole tree, `--trunk` to also move the root onto the latest trunk) |
| Push and open or retarget PRs | `plume stack submit` (`--all` for the whole tree) |
| After a parent PR merged | `plume stack sync` (`--push` also pushes and retargets) |
| Fold staged fixes into earlier stack commits | `plume stack absorb` (`--dry-run` to see where each hunk goes) |
| Back out the last ref-moving command | `plume stack undo` (`--dry-run` first to see what moves) |
