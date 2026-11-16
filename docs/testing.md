# Testing

How to run Plume's tests, read their failures, and write new ones.

## Running tests

```
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests
```

`PlumeUITests` launches the app, so a full `test` run is slow. Prefer `-only-testing:PlumeTests` while iterating.

`-only-testing` with a name that matches no Swift Testing test prints `** TEST SUCCEEDED **` having run nothing, and `-parallel-testing-enabled NO` silently skips Swift Testing suites entirely. Both read as a pass. Confirm the test name appears in the output before believing a green run.

## Reading failures

The console hides Swift Testing's `Expectation failed: …` text and prints only that the test failed. Pass `-resultBundlePath /tmp/x.xcresult`, then read `xcrun xcresulttool get test-results tests --path /tmp/x.xcresult`. A `Crash:` node there means the test host died; its `.ips` in `~/Library/Logs/DiagnosticReports/` has the stack.

When AppKit catches an Objective-C exception raised inside a Swift Testing test, the test host crashes later with `EXC_BAD_ACCESS` in `swift_task_isMainExecutor`, at an unrelated place. The real cause shows in the log as an `NSInternalInconsistencyException`. The case seen here was a synthetic `keyDown` sent while `undoManager.groupsByEvent = false`, with no `beginUndoGrouping`/`endUndoGrouping` around it.

Swift Testing's `#expect` cannot wrap a throwing call. `allSatisfy(\.isHexDigit)` counts as throwing (the closure is `rethrows`), so write `allSatisfy { $0.isHexDigit }`. The failure names a generated macro file, but `…MX45…` in that name is the **line number** in the real source.

## Environmental failures

Some tests depend on the machine that runs them, so a fresh clone fails them for environmental reasons. Check a failure against `main` before believing a regression. If any other test fails on a clean `main`, that is a real failure.

- **`SurfaceCommandTests` needs a real GUI session.** It spawns real `NSWindow`s and PTYs, so it fails from a headless shell.
- **`SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` only asserts where Claude Code has run in this checkout.** It derives the repo path from `#filePath` and locates the transcript directory by the `cwd` Claude Code records, which a worktree or a freshly cloned machine has none of. There its `#require` fails with "Claude Code has not run in …". The test passes once Claude Code has run in your checkout. More than one directory can legitimately record the same `cwd`, because an agent working in a worktree still stamps the parent repository's path, so the test asserts the encoded name is *among* the owning directories rather than the only one.
- **`RealTranscriptCorpusTests` parses every Claude Code transcript on the machine**, so its run time and coverage vary with your history.

## Writing tests

- **Tests that run `git commit` must set `commit.gpgsign false` on the scratch repo.** A signing config that prompts an external agent is unreachable from a test host: the commit hangs ~60s, then fails with exit 128. `WorkspaceProvisionerTests.makeRepository` does this.
- Swift Testing runs suites in parallel in one process, so tests sharing libghostty state can contaminate each other's results.
- **A test that waits on a file watcher must await the store's own read signal, never a wall clock.** `RealTranscriptCorpusTests` parses every transcript on the machine — hundreds of files, tens of seconds — and Swift Testing runs it in parallel with everything else, so a deadline generous enough to look safe still expires under that load. `TranscriptStore.didRead` and `MarkdownFileStore.didRead` exist for this; the `waitUntil` helpers in their suites resume on the signal and finish instantly. Lengthening a timeout only moves the threshold.
