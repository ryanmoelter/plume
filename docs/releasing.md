# Releasing

Plume ships two ways. A **local install** on the machine that builds it — no archive, no DMG — which is how Ryan installs it on his own Macs, and is what most of this document covers. And a **shared build** for other people, packaged as a DMG and attached to a GitHub release; that path is at the end, and `scripts/package-release.sh` runs it.

Both are signed with Developer ID and notarized. That used to be the shared build's distinction, but the sleep helper changed it: Apple documents that `SMAppService` daemons need a notarized app, so the local install is notarized too. The **One-time setup** under *Sharing a build* is a prerequisite for the local install too.

## What a local release is

| | |
|---|---|
| Artifact | `Plume.app`, copied into `/Applications` |
| Signing | Developer ID Application, applied by `scripts/install-release.sh` over the build's automatic signature |
| Notarization | Yes, one round trip to Apple, stapled |
| Audience | The build machine only |

The build itself still signs automatically with the Apple Development identity. The install script re-signs a staged copy, notarizes it, and only then quits the running app and replaces it — so a notarization failure leaves the old install running.

**A release is per-machine.** Plume is developed on more than one Mac, and a build never leaves the one that made it. Tag the version once and push it, then build and install separately on each Mac that wants it. The two installs share nothing — separate bundles, separate stores, separate signatures — so `/Applications/Plume.app` can sit at different versions on each, and the tag says nothing about what is installed anywhere. Check the installed version on the machine in front of you rather than inferring it from the latest tag.

**Release links Ghostty statically.** Sparkle is the one embedded framework: `Contents/Frameworks/Sparkle.framework`, which Xcode embeds and signs automatically at build time — there's no hand-written "Embed Frameworks" phase for it, and adding one breaks the build ("Sparkle-product couldn't be opened"). `otool -L` on the binary reports exactly `@rpath/Sparkle.framework` and nothing else non-system; `install-release.sh` fails if that's not true. If you find yourself hunting for a framework to copy in by hand, something has changed — check that first.

This is a Release-only property. In Debug the real code lives in `Plume.debug.dylib` beside a small launcher stub, which is why `nm` on a Debug binary looks empty.

## Steps

**Tag and release a commit that is already on `main`.** A tag pointing at a release branch names a commit that history may never keep, and the installed build then answers for a version nobody can check out. So the order is: verify on a Debug build, merge to `main`, then build Release from `main` and tag it.

1. Bump the version on the release branch and verify there, with Debug builds.
2. Merge the release branch into `main` (`--no-ff`).
3. Build Release from `main`, and verify the bundle.
4. Tag that commit and push.
5. Install, which signs with Developer ID and notarizes on the way.

Verifying the Debug build before merging is the real gate; the Release verification before tagging is a second look at the artifact itself, not a re-run of the manual checklist.

### 1. Bump the version

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `Plume.xcodeproj/project.pbxproj`. Each appears once per build configuration, for **all three targets** — only the app target's own Debug and Release blocks matter (their bundle identifiers are `com.ryanmoelter.Plume.debug` and `com.ryanmoelter.Plume`). Leave the `PlumeTests` and `PlumeUITests` copies alone; they never reach the shipped bundle.

- `MARKETING_VERSION` is the human version (`0.1.0`) and becomes `CFBundleShortVersionString`.
- `CURRENT_PROJECT_VERSION` is the build number and becomes `CFBundleVersion`. Bump it when you want to tell two installs of the same version apart, and **always bump it for a release** — it's the value Sparkle compares to decide an update exists, so a release that doesn't increase it never reaches anyone.

Then add a section at the top of `CHANGELOG.md` headed `## <MARKETING_VERSION> (<CURRENT_PROJECT_VERSION>)`, and commit it with the bump. `package-release.sh` refuses to build without it. A drafted section is headed `## Draft: <version> (<build>)`. The script refuses to package that too, until you review the notes and remove `Draft: `.

### 2. Build, test, install

Merge to `main` first — see the note above the steps. The Release build and everything after it happen on `main`, so the tag names a commit that stays reachable.

```
git checkout main && git merge --no-ff ryanm/release-<version>
xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' clean build
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests
scripts/install-release.sh
```

`scripts/install-release.sh` does the install and step 3's verification together: it stages a copy of the bundle, re-signs the sleep helper and then the app with Developer ID, notarizes and staples, checks `spctl` says `Notarized Developer ID`, quits the installed Plume, replaces the bundle, prints the version, signature, helper and dylibs, and checks the log for a store moved aside. It writes to `/tmp/plume-install.log` (override with `LOG`). Run the build and tests yourself first — the script only installs, and it refuses if no Release bundle exists.

**The script does not reopen the app**, except when the release was run from inside Plume — there, quitting the app killed the session driving it, and reopening is what brings the conversation back. Open it yourself otherwise.

That exception scrubs `CLAUDE_CODE_CHILD_SESSION` and `CLAUDECODE` from the environment it opens with. An app inherits the shell that launched it and hands that on to every terminal tab it spawns, so a release driven by an agent would otherwise leave each tab's `claude` reading itself as a nested session and skipping its transcript. Launching Plume by hand from an agent's shell has the same effect — use Finder, or `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE open -a Plume`.

Notarization reads the `plume-notary` keychain profile, which can raise a Touch ID prompt. Stay at the keyboard for the run, detached or not.

**Quit a running Plume before copying.** Overwriting a live bundle corrupts the running process. The script waits for a real exit and aborts rather than replacing a bundle still in use.

**Quit Plume, never signal it.** `kill` ends the process without running AppKit's termination path, so `applicationWillTerminate` — and the `closeAll()` that stops this app's agents — never runs. Every agent is then orphaned: it keeps writing its transcript, and the relaunched app resumes that same session, putting two writers on one file. They fork it, and each goes on blind to the other's turns.

Verified by the `Terminating, closing N agent session(s)` log line, which an AppleScript quit produces and a SIGTERM does not. The script quits first and only signals if that fails, then ends any agent still holding Plume's generated `settings.json` and aborts if one will not die.

Check with `ps`, not `pgrep`:

```
ps -ef | grep '[M]acOS/Plume'
```

`pgrep -x Plume` does not reliably match the installed app's own process — it has come back empty while `/Applications/Plume.app` was running, and it matches unrelated test-harness bundles instead. Trust `ps`.

Releasing from a session hosted *inside* Plume is the case to watch, though it survives. `echo $PLUME` says whether you are in one — and an agent should check, since the ancestry (`ps -o ppid=` up the chain) says *which* Plume hosts it, and only the installed one matters.

`scripts/install-release.sh` handles that case itself: with `PLUME` set it re-execs detached under `nohup`, so it outlives both the app and the session that started it, and returns immediately.

**Stop after running the script and wait for Ryan.** The script ends the agent driving it along with every other one, so an agent that carries straight on is talking from a session the relaunched app no longer hosts — and before that was fixed, one that kept running would fork its own transcript. Run the script, say it has been run, and wait to be messaged before doing anything else. The install returns no output either way, because the process that started it is gone by the time the copy finishes.

**The conversation comes back**, in the new app: it relaunches Plume, which restores the session with its context intact. Once Ryan messages, read `/tmp/plume-install.log` — that log is the whole record of what the install did.

Do the tag and push *before* the install. The resume is reliable, but the install is the one step that replaces the app underneath the session, so land anything you would hate to redo first.

Verify the app that came back is the one just installed. Read `CFBundleShortVersionString` from `/Applications/Plume.app/Contents/Info.plist`, and walk the ancestry again to confirm the session's host PID is the relaunched process — not the stale one it started in.

When reading the test output, confirm test names actually scroll past. A `-only-testing` argument that matches nothing prints `** TEST SUCCEEDED **` having run zero tests.

### 3. Verify the bundle

`scripts/install-release.sh` already ran all of this and logged it; these are the same checks by hand, for a manual install or a second look.

```
/usr/libexec/PlistBuddy -c Print /Applications/Plume.app/Contents/Info.plist | grep -i version
codesign --verify --deep --strict /Applications/Plume.app
spctl -a -vvv --type execute /Applications/Plume.app
codesign -d --verbose=2 /Applications/Plume.app/Contents/MacOS/PlumeSleepHelper 2>&1 | grep Authority
otool -L /Applications/Plume.app/Contents/MacOS/Plume | grep -v '/usr/lib\|/System/Library'
```

Expect the version you just set, a silent `codesign` (it only speaks up on failure), `source=Notarized Developer ID` from `spctl`, a `Developer ID Application` authority on the helper, and exactly one non-system dylib: `@rpath/Sparkle.framework`. An `Apple Development` authority anywhere means a re-sign did not take, and the lid-closed toggle will fail to register.

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

Tag the commit that carries the version bump, so the tag and `CFBundleShortVersionString` agree. That commit is on `main` by now; confirm it rather than assuming, since a tag on a branch that later gets rewritten names nothing:

```
git branch --contains v0.1.0 | grep -qx '\* main\|  main' || echo "NOT on main"
```

Check every commit is signed before pushing. Agents fall back to `--no-gpg-sign` when 1Password locks mid-run, and re-signing afterwards means rewriting history the tag already points into:

```
git log --format='%G? %h %s' <last-tag>..main | grep -v '^G'
```

That must print nothing.

## The command-line helper

`plume-notify` ships inside the bundle at `Contents/Resources/plume-notify`, as a plain shell script. The file-system synchronized group puts it there automatically because it lives under `Plume/Resources/`, and both the copy and the signing preserve its executable bit — so nothing in the release path needs a step for it.

It reaches the user's PATH as a symlink at `~/.local/bin/plume-notify`, created from **Settings → Command Line**. A symlink rather than a copy, so the helper follows whatever Plume is installed instead of going stale after an upgrade.

Replacing the bundle does not break the link. `install-release.sh` deletes and recreates `/Applications/Plume.app`, but the link stores a *path*, so it re-resolves to the new bundle. The script prints the link's state after installing; a `BROKEN` line there means the helper stopped shipping, not that the symlink needs recreating.

## The sleep helper

"Keep awake with the lid closed" rides on `PlumeSleepHelper`, a root LaunchDaemon embedded in the bundle. No power assertion survives a lid close; the only thing that does is `SleepDisabled` on `IOPMrootDomain`, which is root-only, so the app cannot set it itself.

Two files ship for it and the build puts both in place:

| | |
|---|---|
| `Contents/MacOS/PlumeSleepHelper` | The daemon, its own target, signed with hardened runtime |
| `Contents/Library/LaunchDaemons/com.ryanmoelter.Plume.SleepHelper.plist` | The launchd job: `BundleProgram`, `MachServices`, `AssociatedBundleIdentifiers` |

**Registration happens in the app, not the installer.** The lid toggle stays disabled until the helper is approved; the "Install Sleep Helper…" button in the Keep Awake popover (or the Settings pane) calls `SMAppService.daemon(plistName:).register()` through `DaemonLidSleepOverride`. A never-registered daemon reads `.notFound` from `SMAppService`, not `.notRegistered` — the app treats both as "not installed".

**Uninstalling** is the "Uninstall…" button beside the helper row in Settings → Keep Awake: it releases the override, calls `unregister()`, and turns the lid setting off. Note that macOS remembers the approval, so a reinstall goes straight to `enabled` with no prompt. To see the true first-run flow again, `sudo sfltool resetbtm` wipes the approval records for *every* app's background items, and each one re-prompts on its next registration. That lands in `requiresApproval`, and macOS shows a notification; the user allows Plume under System Settings → General → Login Items & Extensions → *Allow in the Background*. The panel offers an "Open Login Items…" link while it waits, and polls every two seconds until the status flips to `enabled`. Nothing needs re-registering after an upgrade: launchd keys the job by label and reads the plist out of whatever bundle is at the app's path.

**Notarization is documented as required, but not enforced at registration.** Apple's `SMAppService.h` states that apps containing LaunchDaemons must be notarized. In testing, a Developer ID signed un-notarized bundle *and* the Apple Development Debug build out of DerivedData both registered, got approved, and drove the helper — so the whole flow is testable in Debug. Ship notarized anyway: the header is the contract, and a future macOS may start checking.

**The override persists, so the helper sweeps it.** Writing `SleepDisabled` straight onto `IOPMrootDomain` returns `kIOReturnUnsupported` even as root; the only route that takes is `IOPMSetSystemPowerSetting`, the call behind `pmset disablesleep`, and powerd persists it to `/Library/Preferences/com.apple.PowerManagement.plist`. So a crash could leave the Mac unable to sleep, and the helper is built around not letting that stand: the daemon has `RunAtLoad` so it clears the setting at every boot, clears it on its own launch, when the app's XPC connection drops, and when 90 seconds pass without a heartbeat; the app clears it on termination and whenever the plain assertion is released. The worst case after any crash is "awake until the next boot". If it is ever stuck, `sudo pmset -a disablesleep 0` clears it by hand.

Both sides check the other's code signature by team ID. Re-signing with a different team breaks the XPC handshake — see *Bundle ID and signing team migration*.

### Manual checklist

The tests cover the coordinator's decisions against a fake; the daemon itself needs a real install, and the lid needs a hand. After an install, with the helper installed and approved, the toggle on, and an agent working:

1. System Settings → Login Items & Extensions → *Allow in the Background* lists Plume, enabled.
2. `ioreg -r -n IOPMrootDomain -d 1 | grep SleepDisabled` reads `Yes` while the panel says the lid can stay closed, and `No` after the agent finishes.
3. `/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume.SleepHelper"' --last 10m --info` shows the engage, heartbeat, and release.
4. `kill -9` the running Plume with the override engaged; the same `ioreg` read flips back to `No` within a few seconds.
5. On battery, with both battery and lid toggles on, close the lid for a minute with an agent working. The transcript keeps growing.
6. With the lid still closed, let the agent finish (or turn the lid toggle off). powerd does not revisit a lid that closed while sleep was disabled, so the helper requests the sleep itself about a second after the release (`IOPMSleepSystem`, root only). The helper log shows `lid is closed on release: sleep=true` and then `sleep request … kr=0`, and `pmset -g log` gains a Sleep entry. The app passes `sleepIfLidClosed=false` when an external display is attached, and a release with no client (crash, watchdog) sleeps a shut lid only on battery.

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

An app signed only with an Apple Development identity runs on the machine that signed it and nowhere else; another Mac shows "Plume is damaged and can't be opened" — a misleading way of saying the signature is not valid there. Sharing a build means a **Developer ID Application** signature, notarization, and a stapled ticket, which the local install now does as well. What the shared path adds is the DMG and the release.

`scripts/package-release.sh` does all of it: builds Release, re-signs the helper and then the app with Developer ID, notarizes, builds a drag-to-install DMG, notarizes that too, verifies both, and opens a **draft** GitHub release with the DMG attached. Nothing is public until you publish the draft.

**Hardened runtime is not new here.** `ENABLE_HARDENED_RUNTIME = YES` applies at signing, not at notarization, so every local Release install has already enforced it — `codesign -d` reports `flags=0x10000(runtime)`. Plume spawns PTYs, launches `claude`, and runs `git worktree` under it today. Hardened runtime restricts what is done *to* the process (code injection, unsigned library loads, JIT), not the processes it spawns, which is why there is no `.entitlements` file and none is needed. Notarization adds a malware scan and a Gatekeeper ticket, not new runtime restrictions.

### One-time setup

1. **A Developer ID Application certificate.** Xcode → Settings → Accounts → Manage Certificates → **+** → Developer ID Application. Check with `security find-identity -v -p codesigning`; the script picks the identity up itself.
2. **An app-specific password** from appleid.apple.com. Notarization rejects the account password.
3. **A notary keychain profile**, so the password stays out of the repo and out of shell history:

   ```
   xcrun notarytool store-credentials plume-notary \
     --apple-id <apple id> --team-id U6J478KTGV --password <app-specific password>
   ```

4. **The Sparkle EdDSA key**, once, ever — see *The EdDSA key* below for what it's for. Generate it with the tool that ships inside the resolved Sparkle package:

   ```
   <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle-key
   ```

   This prints the public key and saves the private key to your login keychain and to `/tmp/sparkle-key`. Store the private key in 1Password at `op://Plume/Plume Sparkle EdDSA/private key` (field "private key"), then remove both copies the tool left behind — the keychain is not where `package-release.sh` reads it from, and a private key on disk defeats the point:

   ```
   security delete-generic-password -s https://sparkle-project.org
   rm /tmp/sparkle-key
   ```

   Paste the printed public key into `Configuration/Info.plist`'s `SUPublicEDKey`. The key pair already exists; regenerating it strands every shipped install, which can only verify updates signed with the old key.

Both scripts check for the identity and the profile before building and name the fix for whichever is missing.

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

## Sparkle auto-updates

A DMG install updates itself through Sparkle 2.10.0, pinned exactly. `package-release.sh` builds the appcast that drives it, on top of the DMG steps above.

### The EdDSA key

The private key that signs each update lives only in 1Password, at `op://Plume/Plume Sparkle EdDSA/private key` (override with `SPARKLE_KEY_REF`). `package-release.sh` reads it with `op read "$SPARKLE_KEY_REF" | sign_update --ed-key-file -`, so the key never touches disk or the keychain. `op` must be signed in; the script preflights that and fails early if not.

**Losing this key means every shipped app can never verify another update.** There's no way to reissue trust after the fact, so keep it backed up in 1Password beyond the one entry.

### The appcast

`SUFeedURL`, set in `Configuration/Info.plist`, is fixed: `https://github.com/ryanmoelter/plume/releases/latest/download/appcast.xml`. Every release has to publish an `appcast.xml` describing itself, as a release asset next to the DMG. `package-release.sh` signs the DMG with `sign_update` and writes the file.

The appcast goes live when the draft is published, same as the DMG — a draft or a prerelease never appears to it. Release notes live in `CHANGELOG.md`, one `## <version> (<build>)` section per release, newest first. The top section becomes the GitHub release body. The appcast's description is **cumulative**: it holds the top ten sections, built by `scripts/lib/cumulative-notes.sh`.

- Each release is a `<section data-sparkle-version="<CFBundleVersion>">`, rendered to HTML through GitHub's markdown API. Sparkle marks the section matching the running build `sparkle-installed-version`, and a stylesheet hides it and every older one. A user who skipped releases sees what they missed.
- Each section also embeds its markdown source in a `<script type="text/markdown">` block. The Homebrew update window renders that (`CumulativeReleaseNotes`) instead of the HTML.
- Sparkle's `markdown` format can't do this. It parses with `NSAttributedString`, which drops HTML, so the description is HTML.

### Signing

`scripts/lib/sign-bundle.sh` signs a bundle inside out: Sparkle's `Installer.xpc`, `Downloader.xpc` (with entitlements preserved), `Autoupdate`, `Updater.app`, and `Sparkle.framework`, then `PlumeSleepHelper`, then the app — still no `--deep`. Both `install-release.sh` and `package-release.sh` call it. `install-release.sh` fails unless the only non-system dylib left in the signed binary is `@rpath/Sparkle.framework`.

Xcode embeds and signs `Sparkle.framework` into `Contents/Frameworks` on its own. Don't add a manual "Embed Frameworks" build phase for it — a hand-written one breaks the build with "Sparkle-product couldn't be opened".

### Testing an update end-to-end

There's no way to point Sparkle at a real feed without publishing a release, so test locally instead. For iterating on the update UI or flow, a Debug build needs no publish step at all:

```
xcodebuild -scheme Plume -destination 'platform=macOS' build   # build Debug first
scripts/debug/serve-test-appcast.sh              # version 99.0.0, build 9999 by default
scripts/debug/serve-test-appcast.sh 1.2.3 42     # or pick your own
```

It copies the built Debug app, bumps its version, re-signs it, signs the update with the 1Password EdDSA key, and serves an appcast on `http://localhost:8765`, pointing the Debug build's `PlumeUpdateFeedURLOverride` default at it. Launch the Debug build and open Settings ▸ **Updates (Debug)** — `#if DEBUG` only — to override the install source, apply a feed URL without relaunching, exercise the scheduled/gentle background check on its own, or reset Sparkle's skipped-version and last-check state. Ctrl-C stops the server, removes the temp dir, and clears the default. Installing the update replaces the DerivedData Debug app with the bumped copy; rebuild to restore the real one.

For an install-source test against a genuine **installed Release build** (Developer ID signed, not the script's ad hoc signature) — confirming the Homebrew-vs-Plume detection, say, or a real installer swap — there's no shortcut:

1. Install an older Release build (`scripts/install-release.sh`).
2. Bump the version and build a higher-version signed DMG (`scripts/package-release.sh`, or the DMG steps above by hand).
3. Serve the DMG and the `appcast.xml` that `package-release.sh` wrote — e.g. `python3 -m http.server 8000` from the `out/` directory.
4. Point the installed app at that local feed:
   ```
   defaults write com.ryanmoelter.Plume PlumeUpdateFeedURLOverride http://localhost:8000/appcast.xml
   ```
5. Launch the app and use Check for Updates….
6. `defaults delete com.ryanmoelter.Plume PlumeUpdateFeedURLOverride` afterward, so the installed app goes back to the real feed.

### The first Sparkle-enabled release

Existing DMG installs have no updater yet, so the release that adds Sparkle reaches them only by a manual download from the releases page. Homebrew installs get it the normal way, through `brew upgrade --cask ryanmoelter/tap/plume`.

## Publishing to Homebrew

`ryanmoelter/homebrew-tap` carries a cask, `Casks/plume.rb`, that installs the DMG built above: `brew install ryanmoelter/tap/plume`, `brew upgrade --cask ryanmoelter/tap/plume`. Casks and formulae coexist in that one repo.

The cask carries no `auto_updates` and doesn't need one: Sparkle only tells a Homebrew install that an update exists (detected via a `Caskroom/plume` directory) and offers to run `brew upgrade --cask ryanmoelter/tap/plume` in Terminal.app, rather than installing anything itself. The script reopens Plume afterwards, because the cask's `uninstall quit:` quits it during the upgrade. Brew stays the actual update path for cask users.

After a release is public (not a draft), bump the cask:

```
scripts/update-tap.sh <version>   # e.g. scripts/update-tap.sh 0.12.0
```

It clones `ryanmoelter/homebrew-tap` into `mktemp -d`, downloads that version's DMG, computes its sha256, edits `version`/`sha256` in the cask, commits, and pushes — then deletes the temp clone. It refuses if the release for that version is still a draft, since the DMG URL 404s until publication and hashing then would hash bytes nobody can download.

The script lives in this (public) repo, so it never references a tap checkout on any particular machine — only the tap's repo name.

### Checking the cask

From a machine with the tap already tapped (`brew tap ryanmoelter/tap`):

```
brew style --cask ryanmoelter/tap/plume
brew audit --cask ryanmoelter/tap/plume
brew livecheck ryanmoelter/tap/plume
```

`brew style --cask` refuses to run on a cask file outside a tap, so point it at the tapped name, not a bare path, unless you're working inside an actual tap checkout. `brew audit --cask --new` additionally fails with "GitHub repository not notable enough" — that rule gates submission to homebrew-cask proper, not a personal tap, and is expected here.

**Never run `brew install --cask plume` or `brew uninstall --cask plume` against a Plume you're currently running** — it replaces or removes the live `/Applications/Plume.app` out from under the running process. Test cask changes against a build that isn't the one driving your session, or ask before running either command.

## Bundle ID and signing team migration

Plume is expected to move to company ownership, with the bundle ID becoming `com.gingerlabs.plume` and the signing team changing to the work one. Neither blocks distribution, and they are independent knobs.

**Signing team: one constant to update.** A Mac cares that the signature is valid and notarized, not which team produced it, and there is no auto-updater pinning a team ID. The sleep helper is the exception: the app and the daemon each check the other's signature against `sleepHelperTeamID` in `SleepHelperProtocol.swift`, so a build signed by the work team needs that constant changed with it or the XPC handshake fails.

**Bundle ID: preserves data, resets preferences.** `AppPaths.directoryName` keys only off the `.debug` suffix and otherwise returns a hardcoded `"Plume"`, so the store path is not derived from the bundle ID. Tasks, groups and tabs survive a rename. What resets is the state macOS keys by bundle ID:

- `UserDefaults` / `AppSettings` — window state and everything in the settings pane
- Accessibility and automation permission grants, which prompt again
- Login Items

Warn people on that build. Shipping the rename and the team change together makes it one disruption instead of two.
