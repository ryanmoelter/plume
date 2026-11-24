# Routines

A routine is a prompt Plume starts as a new task on a schedule. The sidebar's Routines row, under Home, opens the page that lists, runs, edits and deletes them. The code is in `Plume/Routines/` and `Plume/UI/Routines/`.

## Model

`Routine` is a SwiftData model. It holds the name, the prompt, the folder (`folderPath`, plus `repoPath` when the folder is in a git repository), whether each run gets a new worktree, the agent choices a tab launches from (provider, model, effort and permission mode, which defaults to `auto`), the trigger, `notifiesOnFinish` and `lastRunAt`. Runs are always headless. The editor reuses the composer's model, effort and permission controls on a tab that is never inserted, the way Home's composer does, and copies its `TabLaunchChoices` into the routine on Save.

What a run did in this app session — its task, or why it failed to start — lives in memory in `RoutineScheduler.lastRuns`. Only `lastRunAt` persists.

## Triggers

`RoutineTrigger` is pure and holds the schedule math:

- `interval(hours:)` runs every N hours.
- `weekly(weekdays:minuteOfDay:)` runs on the chosen days at a local time, in the user's current calendar and time zone. A time that daylight saving skips runs at the next time that exists.
- `once(Date)` runs once. A `once` routine turns itself off when it runs.

The schedule counts from the later of `lastRunAt` and `scheduledFrom`. Creating a routine, turning it on and changing its trigger all set `scheduledFrom` to now. So an interval routine first runs one interval after it is created or turned on, and turning a routine back on never runs the slots it missed while off.

**A missed slot runs once.** When the Mac sleeps or Plume is quit through one or more slots, the next check finds the routine due and runs it one time. That run stamps `lastRunAt` with the time it ran, which leaves nothing owed until the next slot.

## Running

`RoutineScheduler.shared` checks every 30 seconds, on `NSWorkspace.didWakeNotification`, and once a window is ready after launch. It takes the frontmost main window's model context, and runs nothing without a window, because the window installs the callbacks that persist a tab's session ID. A routine already starting is never started again, and the run stamps `lastRunAt` before anything awaits, so a failed run waits for its next slot instead of retrying every tick.

`RoutineRunner` checks the run first: an empty prompt, a missing folder, a missing CLI, or a folder Claude Code hasn't trusted (`ClaudeTrustStore`) fails it before any task exists, and the error shows on the routine's row. It then builds a `HomeTaskPlan` and starts it through `HomeTaskStarter`, as Home does. The task lands in the group whose `TaskGroup.kind` is `routines`, created as "Routines" on the first run and found by kind afterward, so renaming it keeps it. The task takes the routine's name. A run never changes the sidebar selection. A new worktree is named from the routine's name with the repository's branch prefix, and keeps the routine folder's subfolder. A new worktree's trust is only known once the launch refuses it, which `RoutineRunner` reads back from `UntrustedDirectoryStore`.

With `notifiesOnFinish`, the scheduler watches the run's tab through `StatusEngine.setTabStatusObserver` and posts one notification when the turn ends or stops with an error. It uses the same dedupe key as `StatusNotifier`, so the two never stack.

## Driving

`plume routine list` and `plume routine run <name>` (`docs/cli.md`), and the debug control server's `routines.list`, `routines.create`, `routines.run` and `routines.tick`, which takes a fake `now` (`docs/control-server.md`).

## Not built yet

- Triggers from git, GitHub or Linear events.
- Waking the Mac for a run through the sleep helper. A slot passed while asleep runs on wake.
- Remote Control on by default for a run.
- Runs while no main window is open.
