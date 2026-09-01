# Plume

Native macOS app for organizing and parallelizing coding-agent work: a sidebar of tasks in groups, agent/terminal tabs per task, and at-a-glance status.

## The plan

`docs/plans/plume-v1-plan.md` is the working document. It defines phases and work packages (WPs), each sized for one agent session with its own acceptance criteria. **Check off and annotate WPs there as you complete them.** Read it before starting work.

Decisions recorded in the plan are settled — don't relitigate them. Where reality has since diverged from the plan, the plan file carries an `Amendments` section; add to it rather than editing the original text.

## Build and test

```
xcodebuild -scheme Plume -destination 'platform=macOS' build
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests
```

Every WP ends with a clean build and a manual run. `PlumeUITests` launches the app, so a full `test` run is slow — prefer `-only-testing:PlumeTests` while iterating.

## Layout

The Xcode project uses **file-system synchronized groups**: files added under `Plume/` join the target automatically. Adding a source file needs no `project.pbxproj` edit; adding a *package or build setting* does.

```
Plume/
  App/       PlumeApp, MainWindow, PlumeCommands
  Models/    SwiftData models, TaskStore (CRUD/ordering), enums
  Ghostty/   GhosttyRuntime, GhosttyConfigLoader
  Support/   Log
  UI/        Sidebar/, Task/
```

Folders from the plan not yet created (`Sessions/`, `Agent/`, `Status/`, `Workspace/`) arrive with their phases.

## Ghostty

Terminals come from the `GhosttyTerminal` product of `Lakr233/libghostty-spm`, pinned `.exact("1.5.0")`. **`docs/GHOSTTY_PIN.md` is the reference** — pin details, why the wrapper was adopted, config search order, upgrade steps, and the self-vendoring fallback. Read it before touching anything Ghostty-related or upgrading the package.

The wrapper does not call `ghostty_config_load_default_files`, so `GhosttyConfigLoader` finds the user's config itself. Its ordering (Application Support before XDG) is deliberate and test-locked — don't "fix" it to match ghostty's docs page, which is wrong.

## Conventions

- **SwiftData models are the persisted skeleton only.** Live process/terminal state belongs in in-memory `@Observable` objects keyed by model UUID. Never persist anything about a running PTY.
- **Every SwiftData stored property needs a default value**, so lightweight migration keeps working as the schema grows.
- Enums persist as `...Raw` strings with a computed accessor (`workspaceKindRaw` / `workspaceKind`). Keeps migrations trivial.
- Ordering is a dense `orderIndex` per section, rewritten on move. All of it lives in `TaskStore` — keep it out of views.
- Model names avoid colliding with Swift's `Task` and SwiftUI's `Group`: `WorkTask`, `TaskGroup`, `TaskTab`.
- **All `ghostty_*` calls stay in `Plume/Ghostty/`.** The C API is unstable between versions; upgrading should touch one folder.
- Status flows through `StatusEngine` in memory; SwiftData gets only a debounced snapshot in `lastStatusRaw`, never per-event writes.

## Gotchas

- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` means transitive imports don't count. Using `Array.move(fromOffsets:toOffset:)` needs an explicit `import SwiftUI`; `IndexSet` needs `import Foundation`. The error names the missing module.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: everything is MainActor-isolated unless marked otherwise. Test suites touching models need `@MainActor`.
- The app is **unsandboxed** (`ENABLE_APP_SANDBOX = NO`) — it spawns PTYs, reads `~/.claude/**`, and runs `git worktree`. Distribution is Developer ID + notarization, not the App Store. Don't re-enable the sandbox.
- The debug store lives at `~/Library/Application Support/default.store`. Delete it to test first-run behavior.
- SourceKit in-editor diagnostics go stale on new files and report phantom "cannot find type in scope" errors (often resolving `TaskGroup` to Swift's generic one). Trust `xcodebuild`, not the editor squiggles.
- In Debug, `Plume.app/Contents/MacOS/Plume` is a ~57K launcher stub. The real code — and every linked libghostty symbol — is in `Plume.debug.dylib` beside it. Inspecting the stub with `nm` makes it look like nothing is linked.
- `log` is shadowed by a shell function; use `/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume"' --last 5m --info`.
- Adding a *source file* needs no project edit, but adding a *SwiftPM package* means hand-editing `project.pbxproj` (build file, package reference, product dependency, and the Frameworks phase).
- Deployment target is macOS 26.2, matching the Xcode 26.2 SDK ceiling. Raising it above the installed SDK makes every build warn.
