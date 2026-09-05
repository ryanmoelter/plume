# Releasing

Plume currently ships one way: a local install on the machine that builds it. There is no archive, no notarization, and no DMG. This document covers that path only — public distribution is a separate problem, sketched at the end.

## What a local release is

| | |
|---|---|
| Artifact | `Plume.app`, copied into `/Applications` |
| Signing | Automatic, with the Apple Development identity already on the machine |
| Notarization | None |
| Audience | The build machine only |

A Development-signed app runs freely on the Mac that signed it, so Gatekeeper never enters the picture. That is the whole reason this path is so short.

**A release is per-machine.** Plume is developed on more than one Mac, and a build never leaves the one that made it. Tag the version once and push it, then build and install separately on each Mac that wants it. The two installs share nothing — separate bundles, separate stores, separate signatures — so `/Applications/Plume.app` can sit at different versions on each, and the tag says nothing about what is installed anywhere. Check the installed version on the machine in front of you rather than inferring it from the latest tag.

**Release links Ghostty statically.** The Release binary is one self-contained ~13 MB executable: there is no `Contents/Frameworks`, and `otool -L` reports no non-system dylibs. Nothing needs embedding, re-signing, or bundling. If you ever find yourself hunting for a framework to copy, something has changed — check that first.

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
cp -R "$(xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' -showBuildSettings \
  | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/Plume.app" /Applications/
```

**Quit a running Plume before copying.** Overwriting a live bundle corrupts the running process.

When reading the test output, confirm test names actually scroll past. A `-only-testing` argument that matches nothing prints `** TEST SUCCEEDED **` having run zero tests.

### 3. Verify the bundle

```
/usr/libexec/PlistBuddy -c Print /Applications/Plume.app/Contents/Info.plist | grep -i version
codesign --verify --deep --strict /Applications/Plume.app
otool -L /Applications/Plume.app/Contents/MacOS/Plume | grep -v '/usr/lib\|/System/Library'
```

Expect the version you just set, a silent `codesign` (it only speaks up on failure), and no dylibs beyond the binary's own path.

Then launch it and open a terminal tab. Verify the processes rather than a screenshot — surfaces are real PTYs, so the process tree is the better evidence:

```
PID=$(pgrep -x Plume); for l in $(pgrep -P $PID); do pgrep -P $l; done
```

Expect one `login` → `-zsh` per surface. Always walk down from Plume's own PID; a global `pgrep` for `claude` matches the Claude desktop app's helpers and will convince you an agent launched when none did.

### 4. Tag and push

```
git tag -a v0.1.0 -m "v0.1.0"
git push origin main v0.1.0
```

Tag the commit that carries the version bump, so the tag and `CFBundleShortVersionString` agree.

## The store survives releases

Plume's SwiftData store lives at `~/Library/Application Support/Plume/Plume.store`, beside the `hooks` and `events` directories. It is deliberately *not* at SwiftData's default path, so it belongs to Plume alone.

Installing a new build does not touch it — that is the point, and it is what makes upgrading safe. Two consequences:

- **Debug and Release keep separate stores.** The Debug bundle identifier carries a `.debug` suffix and `AppPaths.directoryName` keys off it, so a debug run writes to `Plume.debug/` and the two can run side by side. The catch is that debug testing never exercises the installed app's store, so a schema change meets the real data for the first time when you launch the release.
- **A schema change can outrun lightweight migration.** If the store fails to open, `PlumeApp` moves it aside as `Plume.store.<timestamp>.bak` and starts empty rather than refusing to launch. You get a working app and a recoverable file, not a crash loop. Watch for it:

  ```
  /usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume"' --last 5m --info
  ```

To test first-run behavior, quit the app and delete the store.

## Not yet: public distribution

Shipping to another Mac needs more than this document covers. The shape of it:

- A **Developer ID Application** certificate, which this machine does not have — only Apple Development identities. Gatekeeper rejects a Development-signed app on any other machine.
- **Notarization** and stapling, which is why `ENABLE_HARDENED_RUNTIME = YES` is already set.
- A DMG or ZIP, and somewhere to host it.

The static link means there is still nothing to embed, so the packaging step stays simple whenever this becomes worth doing.
