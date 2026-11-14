package com.ryanmoelter.altitude.extractor

import java.io.File
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** `Wire.serializer()` exists only once the serialization plugin has generated it. */
class CompilerPluginTest {

  @Test
  fun pluginGeneratedDeclarationsResolveWithThePlugin() {
    val call = serializerCall(listOf(serializationPlugin))
    assertTrue(call.target.resolved, "${call.target} ${call.diagnostic}")
    assertEquals("fixture/serialization/Wire.Companion.serializer", call.symbol)
  }

  @Test
  fun pluginGeneratedDeclarationsAreUnresolvedWithoutThePlugin() {
    assertEquals(Target.UNRESOLVED, serializerCall(emptyList()).target)
  }

  private fun serializerCall(plugins: List<Path>): CallSite {
    val module = Fixture.module("serialization").copy(compilerPluginClasspath = plugins)
    return AltitudeSession.open(AnalysisInput(listOf(module))).use(::collectCallSites).single {
      it.site == Site.CALL && it.text == "serializer"
    }
  }

  private val serializationPlugin: Path =
    System.getProperty("java.class.path").split(File.pathSeparator).map(Path::of).single {
      it.fileName.toString().startsWith("kotlin-serialization-compiler-plugin-")
    }
}
