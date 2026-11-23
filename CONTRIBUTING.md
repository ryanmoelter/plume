# Contributing to Plume

`CLAUDE.md` is the working guide to the codebase, for people and agents alike. Read it before your first change. This file covers only first-time setup.

## Requirements

- macOS 26.2 or later.
- Xcode 27. The deployment target is macOS 26.2, but the code uses APIs that only the Xcode 27 SDK has.
- `claude` installed and logged in, to run an agent tab. `codex` and `gh` are optional.
- Git LFS. The repo stores `Plume/Resources/Scrcpy/scrcpy-server` in LFS. Run `git lfs install` once, then `git lfs pull` in your clone. Without it, the jar is a text pointer and physical-device tabs fail with a message that says so.

## Build and test

```
xcodebuild -scheme Plume -destination 'platform=macOS' build
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests
```

A Debug build keeps its data in `~/Library/Application Support/Plume.debug/` (`Plume.debug-<worktree>/` when built from a worktree), so it runs beside an installed Plume without sharing a store.

Some tests fail on a fresh clone for environmental reasons. `docs/testing.md` lists them. To run the UI tests without taking over your screen, use `scripts/vm/plume-vm test` (`docs/vm-testing.md`).

## Signing

The project signs with the maintainer's Apple Developer team, `U6J478KTGV`. To build with your own team, pick it under the target's Signing & Capabilities in Xcode, and leave that change out of your commits.

The app and its sleep helper check each other's signature against that team ID (`sleepHelperTeamID` in `Plume/Support/SleepHelperProtocol.swift`). A build signed by another team therefore cannot reach the helper, and keeping the Mac awake with the lid closed does nothing. Everything else works.

Releases are signed, notarized and published by the maintainer. `docs/releasing.md` has the process and says what a release needs.

## The roadmap

The roadmap lives in a private Linear workspace, and `PLUME-123` references throughout the repo point into it. `.mcp.json` configures the `plume-linear` MCP server that the `roadmap` and `release-cycle` skills use. Ask the maintainer for access; without it, those two skills don't work, and everything else does.

## Branches and commits

Prefix branches with your own name, such as `alex/fix-stale-title`. `CLAUDE.md` has the commit style.
