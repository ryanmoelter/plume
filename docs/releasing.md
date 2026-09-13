# Releasing

Plume ships two ways. A **local install** on the machine that builds it — no archive, no notarization, no DMG — which is how Ryan installs it on his own Macs, and is what most of this document covers. And a **shared build** for other people, which needs a Developer ID signature and notarization; that path is at the end, and `scripts/package-release.sh` runs it.

## What a local release is

| | |
|---|---|
| Artifact | `Plume.app`, copied into `/Applications` |
| Signing | Automatic, with the Apple Development identity already on the machine |
| Notarization | None |
| Audience | The build machine only |

A Development-signed app runs freely on the Mac that signed it, so Gatekeeper never enters the picture. That is the whole reason this path is so short.

**A release is per-machine.** Plume is developed on more than one Mac, and a build never leaves the one that made it. Tag the version once and push it, then build and install separately on each Mac that wants it. The two installs share nothing — separate bundles, separate stores, separate signatures — so `/Applications/Plume.app` can sit at different versions on each, and the tag says nothing about what is installed anywhere. Check the installed version on the machine in front of you rather than inferring it from the latest tag.

**Release links Ghostty statically.** The Release binary is one self-contained ~19 MB executable: there is no `Contents/Frameworks`, and `otool -L` reports no non-system dylibs. Nothing needs embedding, re-signing, or bundling. If you ever find yourself hunting for a framework to copy, something has changed — check that first.

This is a Release-only property. In Debug the real code lives in `Plume.debug.dylib` beside a small launcher stub, which is why `nm` on a Debug binary looks empty.

## Steps

### 1. Bump the version

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `Plume.xcodeproj/project.pbxproj`. Each appears once per build configuration, for **all three targets** — only the app target's own Debug and Release blocks matter (their bundle identifiers are `com.ryanmoelter.Plume.debug` and `com.ryanmoelter.Plume`). Leave the `PlumeTests` and `PlumeUITests` copies alone; they never reach the shipped bundle.

- `MARKETING_VERSION` is the human version (`0.1.0`) and becomes `CFBundleShortVersionString`.
- `CURRENT_PROJECT_VERSION` is the build number and becomes `CFBundleVersion`. Bump it when you want to tell two installs of the same version apart.

### 2. Build, test, install

```
xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' clean build
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests
scripts/install-release.sh
```

`scripts/install-release.sh` does the install and step 3's verification together: it quits the installed Plume, replaces the bundle, prints the version, signature and dylibs, relaunches, walks the process tree, and checks the log for a store moved aside. It writes to `/tmp/plume-install.log` (override with `LOG`). Run the build and tests yourself first — the script only installs, and it refuses if no Release bundle exists.

**Quit a running Plume before copying.** Overwriting a live bundle corrupts the running process. The script waits for a real exit and aborts rather than replacing a bundle still in use.

Check with `ps`, not `pgrep`:

```
ps -ef | grep '[M]acOS/Plume'
```

`pgrep -x Plume` does not reliably match the installed app's own process — it has come back empty while `/Applications/Plume.app` was running, and it matches unrelated test-harness bundles instead. Trust `ps`.

Releasing from a session hosted *inside* Plume is the case to watch, though it survives. `echo $PLUME` says whether you are in one — and an agent should check, since the ancestry (`ps -o ppid=` up the chain) says *which* Plume hosts it, and only the installed one matters.

`scripts/install-release.sh` handles that case itself: with `PLUME` set it re-execs detached under `nohup`, so it outlives both the app and the session that started it, and returns immediately.

**Stop after running the script and wait for Ryan.** The old `claude` process keeps running after the app quits, so an agent that carries straight on is talking from a session the relaunched app no longer hosts. Run the script, say it has been run, and wait to be messaged before doing anything else. The install returns no output either way, because the process that started it is gone by the time the copy finishes.

**The conversation comes back**, in the new app: it relaunches Plume, which restores the session with its context intact. Once Ryan messages, read `/tmp/plume-install.log` — that log is the whole record of what the install did.

Do the tag and push *before* the install. The resume is reliable, but the install is the one step that replaces the app underneath the session, so land anything you would hate to redo first.

Verify the app that came back is the one just installed. Read `CFBundleShortVersionString` from `/Applications/Plume.app/Contents/Info.plist`, and walk the ancestry again to confirm the session's host PID is the relaunched process — not the stale one it started in.

When reading the test output, confirm test names actually scroll past. A `-only-testing` argument that matches nothing prints `** TEST SUCCEEDED **` having run zero tests.

### 3. Verify the bundle

`scripts/install-release.sh` already ran all of this and logged it; these are the same checks by hand, for a manual install or a second look.

```
/usr/libexec/PlistBuddy -c Print /Applications/Plume.app/Contents/Info.plist | grep -i version
codesign --verify --deep --strict /Applications/Plume.app
otool -L /Applications/Plume.app/Contents/MacOS/Plume | grep -v '/usr/lib\|/System/Library'
```

Expect the version you just set, a silent `codesign` (it only speaks up on failure), and no dylibs beyond the binary's own path.

Then launch it and open a terminal tab. Verify the processes rather than a screenshot — surfaces are real PTYs, so the process tree is the better evidence:

```
PID=$(ps -ef | awk '/[M]acOS\/Plume/ {print $2; exit}')
for l in $(pgrep -P $PID); do pgrep -P $l; done
```

Expect one `login` → `-zsh` per surface. Always walk down from Plume's own PID; a global `pgrep` for `claude` matches the Claude desktop app's helpers and will convince you an agent launched when none did.

### 4. Tag and push

```
git tag -a v0.1.0 -m "v0.1.0"
git push origin main v0.1.0
```

Tag the commit that carries the version bump, so the tag and `CFBundleShortVersionString` agree.

## The command-line helper

`plume-notify` ships inside the bundle at `Contents/Resources/plume-notify`, as a plain shell script. The file-system synchronized group puts it there automatically because it lives under `Plume/Resources/`, and both the copy and the signing preserve its executable bit — so nothing in the release path needs a step for it.

It reaches the user's PATH as a symlink at `~/.local/bin/plume-notify`, created from **Settings → Command Line**. A symlink rather than a copy, so the helper follows whatever Plume is installed instead of going stale after an upgrade.

Replacing the bundle does not break the link. `install-release.sh` deletes and recreates `/Applications/Plume.app`, but the link stores a *path*, so it re-resolves to the new bundle. The script prints the link's state after installing; a `BROKEN` line there means the helper stopped shipping, not that the symlink needs recreating.

## The store survives releases

Plume's SwiftData store lives at `~/Library/Application Support/Plume/Plume.store`, beside the `hooks` and `events` directories. It is deliberately *not* at SwiftData's default path, so it belongs to Plume alone.

Installing a new build does not touch it — that is the point, and it is what makes upgrading safe. Two consequences:

- **Debug and Release keep separate stores.** The Debug bundle identifier carries a `.debug` suffix and `AppPaths.directoryName` keys off it, so a debug run writes to `Plume.debug/` and the two can run side by side. The catch is that debug testing never exercises the installed app's store, so a schema change meets the real data for the first time when you launch the release.
- **A schema change can outrun lightweight migration.** If the store fails to open, `PlumeApp` moves it aside as `Plume.store.<timestamp>.bak` and starts empty rather than refusing to launch. You get a working app and a recoverable file, not a crash loop. Watch for it:

  ```
  /usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume"' --last 5m --info
  ```

To test first-run behavior, quit the app and delete the store.

## Sharing a build with other people

The local path above signs with an Apple Development identity, which Gatekeeper accepts only on the machine that signed it. Another Mac shows "Plume is damaged and can't be opened" — a misleading way of saying the signature is not valid there. Sharing a build means a **Developer ID Application** signature, notarization, and a stapled ticket.

`scripts/package-release.sh` does all of it: builds Release, re-signs with Developer ID, notarizes, builds a drag-to-install DMG, notarizes that too, verifies both, and opens a **draft** GitHub release with the DMG attached. Nothing is public until you publish the draft.

**Hardened runtime is not new here.** `ENABLE_HARDENED_RUNTIME = YES` applies at signing, not at notarization, so every local Release install has already enforced it — `codesign -d` reports `flags=0x10000(runtime)`. Plume spawns PTYs, launches `claude`, and runs `git worktree` under it today. Hardened runtime restricts what is done *to* the process (code injection, unsigned library loads, JIT), not the processes it spawns, which is why there is no `.entitlements` file and none is needed. Notarization adds a malware scan and a Gatekeeper ticket, not new runtime restrictions.

### One-time setup

1. **A Developer ID Application certificate.** Xcode → Settings → Accounts → Manage Certificates → **+** → Developer ID Application. Check with `security find-identity -v -p codesigning`; the script picks the identity up itself.
2. **An app-specific password** from appleid.apple.com. Notarization rejects the account password.
3. **A notary keychain profile**, so the password stays out of the repo and out of shell history:

   ```
   xcrun notarytool store-credentials plume-notary \
     --apple-id <apple id> --team-id U6J478KTGV --password <app-specific password>
   ```

The script checks all three before building and names the fix for whichever is missing.

### Running it

```
scripts/package-release.sh
```

It refuses on a dirty tree, so commit the version bump first. Notarization is two round trips to Apple, a few minutes each. Output goes to `/tmp/plume-package.log` (override with `LOG`) and the DMG to `out/` (override with `OUT`).

The version comes from the app target's `MARKETING_VERSION`, and the tag is `v<version>`. **The script never creates the tag.** On the first run it builds and notarizes, then stops and tells you to tag — so a build that fails notarization never leaves a tag behind. Tag as in step 4 above, then re-run to attach the DMG:

```
git tag -a v0.5.1 -m "v0.5.1"
git push origin main v0.5.1
scripts/package-release.sh
```

The second run reuses nothing — it rebuilds and re-notarizes, which takes the same few minutes. It also refuses if the tag points anywhere but `HEAD`, so the DMG and the tagged source always agree.

Then review the draft on GitHub and publish it:

```
gh release edit v0.5.1 --draft=false
```

### The DMG is built with `hdiutil`, not `create-dmg`

`create-dmg` makes a prettier window — positioned icons, a sized frame — by mounting a read-write image, styling it with AppleScript, ejecting, then converting. On macOS 26 that final conversion fails:

```
CBSDBackingStore::newProbe stat() failed.  No such file or directory.
hdiutil: convert failed - Resource temporarily unavailable
```

The ejected intermediate points at a backing store that no longer exists, and nothing recovers it — retrying converts the same broken image. `hdiutil create` from the same staged folder works instantly and produces a smaller file (9 MB against a 27 MB intermediate).

So the DMG is plain: `Plume.app` beside an `/Applications` symlink, unstyled. Dragging one onto the other installs it. If someone revisits this, the styling is the only thing to gain.

`hdiutil` does not sign, so the script signs the DMG itself before notarizing it.

### Why the DMG is notarized separately

Gatekeeper evaluates the *downloaded file*. A stapled app inside an unnotarized DMG still warns the first time someone opens it, and that failure is invisible on the machine that built it — the build machine has no quarantine attribute to trigger it. The script notarizes and staples both, then verifies both. To check by hand, simulate a download:

```
xattr -w com.apple.quarantine "0081;00000000;Safari;" out/Plume-0.5.0.dmg
spctl -a -vvv --type open --context context:primary-signature out/Plume-0.5.0.dmg
```

Expect `accepted` and `source=Notarized Developer ID`. An `Apple Development` authority in `codesign -d` output means the re-sign silently did not take.

**The real check is someone else's Mac.** Every check above can pass on the build machine while a signing mistake still bites elsewhere. Have one person install before announcing it broadly.

### What to tell people

Open the DMG, drag Plume to Applications. A correctly notarized build opens normally — **if anyone needs the right-click → Open workaround, the notarization is broken**, and that is the signal to check it rather than to talk them through the workaround.

First launch prompts for permissions this machine granted long ago, since Plume spawns terminals and reads `~/.claude/**`. Plume also needs `claude` on the PATH; a GUI-launched app does not inherit a shell PATH, which is why both transports go through `LoginShellCommand.wrap`.

## Bundle ID and signing team migration

Plume is expected to move to company ownership, with the bundle ID becoming `com.gingerlabs.plume` and the signing team changing to the work one. Neither blocks distribution, and they are independent knobs.

**Signing team: free to change.** Nothing user-visible depends on it. A Mac cares that the signature is valid and notarized, not which team produced it. There is no auto-updater pinning a team ID.

**Bundle ID: preserves data, resets preferences.** `AppPaths.directoryName` keys only off the `.debug` suffix and otherwise returns a hardcoded `"Plume"`, so the store path is not derived from the bundle ID. Tasks, groups and tabs survive a rename. What resets is the state macOS keys by bundle ID:

- `UserDefaults` / `AppSettings` — window state and everything in the settings pane
- Accessibility and automation permission grants, which prompt again
- Login Items

Warn people on that build. Shipping the rename and the team change together makes it one disruption instead of two.
