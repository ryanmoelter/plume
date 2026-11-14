package com.ryanmoelter.altitude.extractor

import java.io.File
import java.nio.file.Path
import kotlin.io.path.extension
import kotlin.io.path.invariantSeparatorsPathString
import kotlin.io.path.isRegularFile
import kotlin.io.path.relativeTo
import kotlin.io.path.walk

/**
 * The sources under `src/test/resources/fixture`: `core` is a multiplatform module with a `common`
 * and a `jvm` fragment, and `app` depends on it.
 */
object Fixture {
  private val root: Path = Path.of(checkNotNull(javaClass.getResource("/fixture")).toURI())

  private val libraries: List<Path> =
    System.getProperty("altitude.fixtureClasspath").split(File.pathSeparator).map(Path::of)

  val input: AnalysisInput =
    AnalysisInput(
      listOf(
        ModuleInput(
          name = ":app",
          sources = sources("app"),
          classpath = libraries,
          moduleDependencies = listOf(":core"),
        ),
        ModuleInput(
          name = ":core",
          sources = sources("core"),
          fragments = listOf(FragmentInput("common"), FragmentInput("jvm", dependsOn = listOf("common"))),
          classpath = libraries,
        ),
      )
    )

  fun module(directory: String): ModuleInput =
    ModuleInput(name = ":$directory", sources = sources(directory), classpath = libraries)

  val sites: List<CallSite> by lazy { AltitudeSession.open(input).use(::collectCallSites) }

  private fun sources(directory: String): List<SourceInput> =
    root
      .resolve(directory)
      .walk()
      .filter { it.isRegularFile() && it.extension == "kt" }
      .map { file ->
        val relative = file.relativeTo(root).invariantSeparatorsPathString
        SourceInput(
          file,
          relative,
          generated = "/generated/" in relative,
          fragment = if (directory == "core") relative.split("/")[1].replace("generated", "common") else null,
        )
      }
      .sortedBy { it.relativePath }
      .toList()
}
