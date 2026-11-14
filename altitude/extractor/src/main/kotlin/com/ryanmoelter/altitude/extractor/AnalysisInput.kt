package com.ryanmoelter.altitude.extractor

import java.nio.file.Path

/** The compilations one Analysis API session mirrors, each as a source module. */
data class AnalysisInput(val modules: List<ModuleInput>)

data class ModuleInput(
  val name: String,
  val sources: List<SourceInput>,
  /**
   * The multiplatform source sets the compiler treats as separate fragments, each before the ones
   * that depend on it. Empty when the sources are one fragment.
   */
  val fragments: List<FragmentInput> = emptyList(),
  /** Binary roots in the order the compiler sees them, without the JDK or Android SDK. */
  val classpath: List<Path> = emptyList(),
  /** Names of the other [ModuleInput]s this one compiles against. */
  val moduleDependencies: List<String> = emptyList(),
  val platform: Platform = Platform.JVM,
  /** Null uses the JDK running the extractor. Ignored on [Platform.ANDROID]. */
  val jdkHome: Path? = null,
  /** `android.jar` and its optional libraries. */
  val bootClasspath: List<Path> = emptyList(),
  val jvmTarget: String? = null,
  val languageVersion: String? = null,
  val apiVersion: String? = null,
  /** Compiler arguments beyond the versions and JVM target, such as `-Xcontext-parameters`. */
  val compilerArgs: List<String> = emptyList(),
  val compilerPluginClasspath: List<Path> = emptyList(),
  /** `plugin:<id>:<key>=<value>` strings. */
  val compilerPluginOptions: List<String> = emptyList(),
)

data class SourceInput(
  val path: Path,
  /** `/`-separated and relative to the repository root; the only form the output uses. */
  val relativePath: String,
  val generated: Boolean,
  /** A [FragmentInput.name]; null puts the file in the module's last fragment. */
  val fragment: String? = null,
  /** The source set that declares the file's root. */
  val sourceSet: String? = null,
)

/**
 * An `expect` declaration resolves only when its `actual` sits in a fragment that depends on the
 * `expect`'s own; in one fragment a call to the pair is ambiguous.
 */
data class FragmentInput(val name: String, val dependsOn: List<String> = emptyList())

enum class Platform {
  JVM,
  ANDROID,
}
