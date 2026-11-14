package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.manifest.Compilation
import com.ryanmoelter.altitude.manifest.Manifest
import java.nio.file.Path
import java.util.zip.ZipFile
import kotlin.io.path.isRegularFile
import kotlin.io.path.name

private const val PLUGIN_SERVICE =
  "META-INF/services/org.jetbrains.kotlin.compiler.plugin.CompilerPluginRegistrar"

/**
 * Maps each compilation to a source module named after its Gradle project. A classpath entry that
 * is another mirrored project's output becomes a dependency on that project's module, so its
 * sources are analysed rather than its class files.
 */
fun Manifest.toAnalysisInput(compilerPlugins: Boolean = true): AnalysisInput {
  val chosen = compilations.groupBy { it.projectPath }.mapValues { (_, all) -> preferred(all) }
  return AnalysisInput(chosen.values.map { it.toModuleInput(chosen.keys, compilerPlugins) })
}

/** One compilation per project: production code, and the debug variant where there are several. */
private fun preferred(compilations: List<Compilation>): Compilation {
  val production =
    compilations.filterNot { it.compilationName.orEmpty().contains("test", ignoreCase = true) }
  val candidates = production.ifEmpty { compilations }
  return candidates.firstOrNull { it.compilationName == "main" }
    ?: candidates.firstOrNull { it.compilationName == "debug" }
    ?: candidates.minBy { it.compilationName.orEmpty() }
}

private fun Compilation.toModuleInput(projects: Set<String>, compilerPlugins: Boolean): ModuleInput {
  val otherProjects = projects - projectPath
  val boot = bootClasspath.toSet()
  return ModuleInput(
    name = projectPath,
    sources =
      sourceFiles
        .filter { it.path.endsWith(".kt") || it.path.endsWith(".java") }
        .map {
          SourceInput(
            Path.of(it.path),
            stablePath(it.relativePath ?: it.path, it.generated),
            it.generated,
            it.fragment,
            it.sourceSet,
          )
        },
    fragments = fragments(),
    classpath =
      classpath.filter { it.moduleRef !in otherProjects && it.path !in boot }.map { Path.of(it.path) },
    moduleDependencies = classpath.mapNotNull { it.moduleRef }.filter { it in otherProjects }.distinct(),
    platform = if (platform == "androidJvm") Platform.ANDROID else Platform.JVM,
    jdkHome = jdkHome?.let(Path::of),
    bootClasspath = bootClasspath.map(Path::of),
    jvmTarget = jvmTarget,
    languageVersion = languageVersion,
    apiVersion = apiVersion,
    compilerArgs = freeCompilerArgs.filter(::affectsResolution) + optIn.map { "-opt-in=$it" },
    compilerPluginClasspath =
      if (compilerPlugins) this.compilerPlugins.classpath.map(Path::of).filter(::isResolutionPlugin)
      else emptyList(),
    compilerPluginOptions =
      if (compilerPlugins) {
        this.compilerPlugins.options
          .filter { it.pluginId != COMPOSE_PLUGIN_ID }
          .map { "plugin:${it.pluginId}:${it.key}=${it.value}" }
      } else {
        emptyList()
      },
  )
}

/**
 * A generated file's path names its Gradle project instead of the build directory, so facts do not
 * change with where a build puts its output: `shared/build/generated/x` becomes
 * `gen/shared/generated/x`, and the root project's `build/x` becomes `gen/_root/x`.
 */
private fun Compilation.stablePath(relativePath: String, generated: Boolean): String {
  if (!generated) return relativePath
  val buildDir = if (projectDir.isEmpty()) "build/" else "$projectDir/build/"
  if (!relativePath.startsWith(buildDir)) return relativePath
  val project = projectPath.trim(':').replace(':', '/').ifEmpty { "_root" }
  return "gen/$project/${relativePath.removePrefix(buildDir)}"
}

/** The fragments that hold files, each after the ones it depends on; empty when there is one. */
private fun Compilation.fragments(): List<FragmentInput> {
  val names = sourceFiles.mapNotNull { it.fragment }.distinct()
  if (names.size < 2) return emptyList()
  val direct = sourceSets.associate { it.name to it.dependsOn }
  fun ancestors(name: String): Set<String> =
    direct[name].orEmpty().flatMap { ancestors(it) + it }.toSet()
  return names
    .map { name -> FragmentInput(name, ancestors(name).filter { it in names }.sorted()) }
    .sortedWith(compareBy({ it.dependsOn.size }, { it.name }))
}

private const val COMPOSE_PLUGIN_ID = "androidx.compose.compiler.plugins.kotlin"

/**
 * Scripting registers through the same service, but only serves `.kts` files. Compose declares
 * nothing a call resolves to, and in a standalone session it makes composable lambdas passed to
 * library functions fail to type-check.
 */
private fun isResolutionPlugin(jar: Path): Boolean =
  jar.isRegularFile() &&
    !jar.name.startsWith("kotlin-scripting-") &&
    !jar.name.startsWith("kotlin-compose-compiler-plugin") &&
    ZipFile(jar.toFile()).use { it.getEntry(PLUGIN_SERVICE) != null }

/** Drops the arguments that name files, which the manifest already carries in its own fields. */
private fun affectsResolution(argument: String): Boolean =
  argument.startsWith("-X") &&
    !argument.startsWith("-Xplugin") &&
    !argument.startsWith("-Xcompiler-plugin-order") &&
    !argument.startsWith("-Xfriend-paths") &&
    !argument.startsWith("-Xfragment") &&
    !argument.startsWith("-Xmulti-platform")
