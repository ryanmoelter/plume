# Altitude

Altitude is a deterministic Kotlin analyzer that emits data-flow facts for architecture visualization.
It is exploratory and tracked as PLUME-205.
Build it with `./gradlew build`.

## Compilation manifest

The extractor reads a JSON manifest that describes each Kotlin compilation of the target build: source files and roots (generated ones included), classpath, compiler options, compiler plugins and JDK. `manifest/` holds the schema (`Manifest.read(path)`), and `gradle/altitude.init.gradle` exports it without changing a file in the target repository.

```
bin/altitude-manifest <target-worktree> <out-dir> [gradle args...]
```

The wrapper picks the JDK from the target's `.sdkmanrc`, sets `ANDROID_HOME` for an Android build when it is unset, and runs:

```
./gradlew -I <abs>/altitude/gradle/altitude.init.gradle altitudeManifest -Paltitude.out=<out-dir>
```

It writes `<out-dir>/manifest.json`. The output is byte-identical across runs of the same checkout.

- **Selection.** The script takes every compilation on a `jvm` target named `main`, and on an `androidJvm` target named after `-Paltitude.androidVariant` (default `debug`). It skips test, metadata and native compilations. `-Paltitude.compileTasks=:app:compileDebugKotlin,:compileKotlin` replaces the rule with an explicit list, and fails on a name that matches no compilation.
- **What runs.** The export depends on what each selected compile task depends on, minus Kotlin compile tasks of the same project: KSP, Apollo, SQLDelight, BuildConfig and R generation, and the jars of other projects on the classpath. A project-to-project dependency therefore still compiles the producing project (`:app` compiles `:shared`).
- **Source sets.** `sourceSet` is the source set that declares the file's root. `fragment` is the K2 multiplatform fragment, which puts all platform source sets (`androidMain`, `androidDebug`) into the compilation's default one. A file no source set declares, such as AGP's `BuildConfig.java`, has no source set; its root is inferred from its `package` line.
- **Generated.** A path is generated when it lies under any project's build directory. A classpath entry under a build directory carries that project as `moduleRef`, including the compilation's own project (its `R.jar`, for instance).
- **Configuration cache.** Each project gets an `altitudeCompilations` task that writes a part file, and the root `altitudeManifest` merges them, because a task may only serialize file collections its own project owns.

## Facts, solver and trace

`extractor facts --manifest <manifest.json> --out <dir>` resolves the sources with the Analysis API and writes one sorted JSON Lines file per relation: declarations, calls, arguments and value-flow edges. It then runs the solver, which tracks function values to the calls that invoke them and resolves virtual calls by class hierarchy. `extractor trace` prints a call path between two declarations as text a reader can check against the source, and `trace --value` prints the path a value takes. `docs/facts.md` is the reference for the schema, the identifiers, the approximations and the trace format.

Library behavior comes from the models under `models/`: what `map`, `launch` or `MutableStateFlow.update` do with their arguments. `docs/models.md` is the reference.

Build the command with `./gradlew :extractor:installDist`; it lands in `extractor/build/install/extractor/bin/extractor`.

`bin/altitude-golden` regenerates the traces under `golden/` from each target's manifest and diffs them. It skips a target whose manifest is absent.
