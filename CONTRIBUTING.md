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

The roadmap lives in a private Linear workspace, and `PLUME-123` references throughout the repo point into it. `.mcp.json` configures the `plume-linear` MCP server for Claude Code; `.codex/config.toml` configures the same server for Codex. Ask the maintainer for access to private roadmap operations. Local builds and tests do not need Linear access.

## Agent setup

Claude Code reads `CLAUDE.md` automatically. Codex uses the same file through `project_doc_fallback_filenames` in `.codex/config.toml`. That config raises `project_doc_max_bytes` to 64 KiB so Codex reads the whole guide. Keep the guide in one place rather than copying it into `AGENTS.md`.

Open this checkout as a trusted project in Codex so it loads `.codex/config.toml`. Sign in to the `plume-linear` MCP server in the agent you use. Start a new chat after changing project configuration or adding skills.

Project skills live in `.claude/skills/`, with Codex discovery through `.agents/skills/`. Invoke a skill by name, such as `/roadmap` in Claude Code or `$roadmap` in Codex. Read each skill's instructions before running its workflow.

## Branches and commits

Prefix branches with your own name, such as `alex/fix-stale-title`. `CLAUDE.md` has the commit style.
