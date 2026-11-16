package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.FactStore
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.MetaFact
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private const val F = "app/src/main/kotlin/app/Repo.kt"

class ExportIdTest {
  private fun factsDir(className: String): Path {
    val dir = Files.createTempDirectory("facts")
    val cls = DeclFact("class:app/$className", "class", className, "file:$F", F, "1:1-5:1")
    val fn = DeclFact("fun:app/$className.load()", "fun", "load", cls.sym, F, "2:1-4:1")
    FactStore.write(dir, Facts(files = listOf(FileFact(F, ":app", generated = false, sourceSet = "main")), decls = listOf(cls, fn)), MetaFact())
    return dir
  }

  private fun ids(facts: Path, split: Boolean = false): Set<String> {
    val out = Files.createTempDirectory("export")
    export(facts, out, "sample", golden = null, split = split)
    return out.listDirectoryEntries("*.json").mapTo(HashSet()) { Json.parseToJsonElement(it.readText()).jsonObject.getValue("meta").jsonObject.getValue("exportId").jsonPrimitive.content }
  }

  @Test
  fun everyFileOfOneExportCarriesTheSameIdAndARunAgainGivesItBack() {
    val facts = factsDir("Repo")
    val first = ids(facts, split = true)
    assertEquals(1, first.size)
    assertEquals(first, ids(facts, split = true))
  }

  @Test
  fun otherFactsOrOptionsGiveAnotherId() {
    val facts = factsDir("Repo")
    assertNotEquals(ids(facts), ids(facts, split = true))
    assertNotEquals(ids(facts), ids(factsDir("Store")))
  }
}
