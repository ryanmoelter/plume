package com.ryanmoelter.altitude.manifest

import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ManifestTest {
  private val sample: Manifest =
    Manifest.read(Path.of(javaClass.getResource("/sample-manifest.json")!!.toURI()))

  @Test
  fun readsTopLevelFields() {
    assertEquals("/work/sample", sample.repoRoot)
    assertEquals(GitInfo("0123456789abcdef0123456789abcdef01234567", dirty = false), sample.git)
    assertEquals("2.4.20", sample.kotlinPluginVersion)
  }

  @Test
  fun readsACompilation() {
    val shared = sample.compilations.single()

    assertEquals(":shared", shared.projectPath)
    assertEquals("androidJvm", shared.platform)
    assertEquals(listOf("commonMain"), shared.sourceSets.first { it.name == "androidMain" }.dependsOn)
    assertEquals(
      listOf(true, false),
      shared.sourceFiles.map { it.generated },
    )
    assertEquals("commonMain", shared.sourceFiles.first().fragment)
    assertNull(shared.sourceFiles.last().fragment)
  }

  @Test
  fun keepsClasspathOrderAndModuleRefs() {
    val classpath = sample.compilations.single().classpath

    assertEquals("/sdk/platforms/android-36/android.jar", classpath.first().path)
    assertNull(classpath[1].moduleRef)
    assertEquals(":lib", classpath[2].moduleRef)
    assertEquals(false, classpath[2].exists)
  }

  @Test
  fun defaultsAbsentFields() {
    val minimal =
      Manifest.parse(
        """{"repoRoot":"/r","compilations":[{"projectPath":":","projectDir":"","compileTask":"compileKotlin","platform":"jvm"}]}"""
      )

    val compilation = minimal.compilations.single()
    assertEquals(1, minimal.schemaVersion)
    assertEquals(emptyList(), compilation.classpath)
    assertEquals(CompilerPlugins(), compilation.compilerPlugins)
  }
}
