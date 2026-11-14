package com.ryanmoelter.altitude.manifest

import java.nio.file.Path
import kotlin.io.path.readText
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * What `altitude/gradle/altitude.init.gradle` exports from a Gradle build: one [Compilation] per
 * Kotlin compilation Altitude mirrors.
 *
 * Absolute paths are machine-local. Every source path also has a repo-relative form
 * (`relativePath`, `/`-separated), which is what path-independent facts must use; it is null only
 * for a file outside [repoRoot].
 *
 * Fields are only ever added, each with a default, so an older reader keeps working.
 */
@Serializable
data class Manifest(
  val schemaVersion: Int = 1,
  val repoRoot: String,
  val git: GitInfo? = null,
  val gradleVersion: String? = null,
  val kotlinPluginVersion: String? = null,
  val androidPluginVersion: String? = null,
  val compilations: List<Compilation> = emptyList(),
) {
  companion object {
    @OptIn(ExperimentalSerializationApi::class)
    val json = Json {
      ignoreUnknownKeys = true
      explicitNulls = false
      prettyPrint = true
    }

    fun read(path: Path): Manifest = parse(path.readText())

    fun parse(text: String): Manifest = json.decodeFromString(serializer(), text)
  }
}

@Serializable data class GitInfo(val sha: String, val dirty: Boolean)

@Serializable
data class Compilation(
  /** Gradle project path: `:` for the root project, `:shared` for a subproject. */
  val projectPath: String,
  /** The project directory relative to the repo root; `""` for the root project. */
  val projectDir: String,
  val compileTask: String,
  /** The Kotlin compilation name, such as `main` or `debug`. */
  val compilationName: String? = null,
  /** The Kotlin target name, such as `android` or `jvm`, when the build has several. */
  val targetName: String? = null,
  /** The Kotlin platform type: `jvm` or `androidJvm`. */
  val platform: String,
  val moduleName: String? = null,
  val languageVersion: String? = null,
  val apiVersion: String? = null,
  val jvmTarget: String? = null,
  val freeCompilerArgs: List<String> = emptyList(),
  val optIn: List<String> = emptyList(),
  val compilerPlugins: CompilerPlugins = CompilerPlugins(),
  /** The Kotlin source sets this compilation compiles, sorted by name. */
  val sourceSets: List<SourceSet> = emptyList(),
  /** Every source root, declared or inferred, sorted by [SourceRoot.path]. */
  val sourceRoots: List<SourceRoot> = emptyList(),
  /** The `.kt` and `.java` files the compile task reads, sorted by [SourceFile.path]. */
  val sourceFiles: List<SourceFile> = emptyList(),
  /** The compile classpath in the order the compiler sees it. */
  val classpath: List<ClasspathEntry> = emptyList(),
  /** Outputs whose `internal` declarations this compilation may see, such as main for a test. */
  val friendPaths: List<String> = emptyList(),
  val jdkHome: String? = null,
  /** `android.jar` and its optional libraries; empty off Android. */
  val bootClasspath: List<String> = emptyList(),
)

@Serializable
data class CompilerPlugins(
  val classpath: List<String> = emptyList(),
  /** Sorted by plugin id, then key; a key may repeat with different values. */
  val options: List<PluginOption> = emptyList(),
)

@Serializable data class PluginOption(val pluginId: String, val key: String, val value: String)

@Serializable
data class SourceSet(
  val name: String,
  /** Names of the source sets this one depends on, such as `commonMain` for `androidMain`. */
  val dependsOn: List<String> = emptyList(),
)

@Serializable
data class SourceRoot(
  val path: String,
  val relativePath: String? = null,
  /** True when the root lives under a project's build directory. */
  val generated: Boolean,
  /** Null when no source set declares the root, such as AGP's `BuildConfig` output. */
  val sourceSet: String? = null,
  val exists: Boolean = true,
)

@Serializable
data class SourceFile(
  val path: String,
  val relativePath: String? = null,
  val generated: Boolean,
  /** The [SourceRoot.path] holding the file. */
  val root: String? = null,
  val sourceSet: String? = null,
)

@Serializable
data class ClasspathEntry(
  val path: String,
  /** The Gradle project path when the entry is a project's build output, its own included. */
  val moduleRef: String? = null,
  val exists: Boolean = true,
)
