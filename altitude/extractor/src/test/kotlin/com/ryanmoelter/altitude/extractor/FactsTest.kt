package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.FactStore
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.solver.solve
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FactsTest {
  private fun write(facts: Facts): Map<String, String> {
    val dir = Files.createTempDirectory("altitude-facts")
    FactStore.write(dir, facts, MetaFact())
    FactStore.writeDerived(dir, solve(FactStore.read(dir)))
    return dir.listDirectoryEntries().associate { it.name to it.readText() }
  }

  @Test
  fun twoRunsWriteTheSameBytes() {
    val first = write(FlowFixture.extract())
    val second = write(FlowFixture.extract())
    assertEquals(first.keys, second.keys)
    for ((name, text) in first) assertEquals(text, second[name], name)
    assertTrue(first.getValue("decl.jsonl").isNotEmpty())
    assertTrue(first.getValue("callEdge.jsonl").isNotEmpty())
  }

  @Test
  fun outputNamesNoAbsolutePath() {
    val root = Path.of("").toAbsolutePath().root.toString()
    val home = System.getProperty("user.home")
    for ((name, text) in write(FlowFixture.facts)) {
      assertFalse(home in text, "$name names the home directory")
      assertFalse("\"$root" in text, "$name has a value that starts at the file system root")
    }
  }

  @Test
  fun declarationIdsAreUnique() {
    val multiplatform = AltitudeSession.open(Fixture.input).use(::extractFacts)
    for (facts in listOf(FlowFixture.facts, multiplatform)) {
      val repeated = facts.decls.groupingBy { it.sym }.eachCount().filterValues { it > 1 }
      assertEquals(emptyMap(), repeated)
    }
  }

  @Test
  fun expectAndActualAreTwoDeclarationsLinkedByActualFor() {
    val facts = AltitudeSession.open(Fixture.input).use(::extractFacts)
    val links = facts.actuals.associate { it.actual to it.expect }
    assertEquals("fun:fixture/core/platformName()|expect", links["fun:fixture/core/platformName()"])
    assertEquals("class:fixture/core/Clock|expect", links["class:fixture/core/Clock"])
    val declared = facts.decls.map { it.sym }.toSet()
    assertTrue(links.keys.all { it in declared } && links.values.all { it in declared })
  }

  @Test
  fun overloadsGetDistinctIds() {
    val ids = FlowFixture.facts.decls.filter { it.name == "editInGraph" && it.owner == "class:fixture/flow/Graphable" }
    assertEquals(
      setOf("prop:fixture/flow/Graphable.editInGraph", "fun:fixture/flow/Graphable.editInGraph(fixture/flow/Delta)"),
      ids.map { it.sym }.toSet(),
    )
  }

  @Test
  fun everyFlowAndCallNamesAKnownSite() {
    val facts = FlowFixture.facts
    val files = facts.files.map { it.path }.toSet()
    assertEquals(setOf("flow/Args.kt", "flow/Dispatch.kt", "flow/Edit.kt", "flow/Receiver.kt"), files)
    assertTrue(facts.calls.all { call -> files.any { call.id.startsWith("$it:") } })
    assertTrue(facts.flows.all { flow -> files.any { flow.at.startsWith("$it:") } })
    assertEquals(emptyList(), facts.unresolved)
  }
}
