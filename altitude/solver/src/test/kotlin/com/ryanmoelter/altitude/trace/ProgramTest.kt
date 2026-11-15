package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.CellFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.NodeFact
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val FILE = "src/App.kt"
private const val TEST_FILE = "src/AppTest.kt"

class ProgramTest {
  private fun function(name: String, file: String = FILE, owner: String? = null) =
    DeclFact("fun:app/$name()", "fun", name, owner, file, "1:1-1:9")

  private fun node(line: Int, kind: String, scope: DeclFact) =
    NodeFact("${scope.file}:$line:1-$line:9:$kind", kind, scope.sym)

  private fun summary(from: String, to: String, line: Int) = FlowFact(from, to, "summary", "$FILE:$line:1-$line:9", "model#entry")

  private val maker = function("maker")
  private val reader = function("reader")
  private val list = node(1, "callResult", maker)
  private val readInMaker = node(2, "callResult", maker)
  private val readInReader = node(3, "callResult", reader)
  private val slot = list.id + "#<elem>"

  private fun program(cells: List<CellFact> = emptyList(), contextFlows: List<FlowFact> = emptyList()) =
    Program(
      Facts(
        files = listOf(FileFact(FILE, ":", generated = false), FileFact(TEST_FILE, ":", generated = false, sourceSet = "unitTest")),
        decls = listOf(maker, reader),
        nodes = listOf(list, readInMaker, readInReader),
      ),
      Derived(cells = cells, contextFlows = contextFlows),
    )

  @Test
  fun costsCompareMostImportantFirst() {
    val ordered =
      listOf(
        PathCost(0, 0, 0, 0, 1),
        PathCost(0, 0, 0, 1, 0),
        PathCost(0, 0, 1, 0, 0),
        PathCost(0, 1, 0, 0, 0),
        PathCost(1, 0, 0, 0, 0),
      )
    assertEquals(ordered, ordered.shuffled(java.util.Random(1)).sorted())
    assertTrue(PathCost(0, 1, 0, 0, 0) > PathCost(0, 0, 99, 99, 99))
    assertEquals(PathCost(1, 2, 3, 4, 5), PathCost(1, 1, 1, 1, 1) + PathCost(0, 1, 2, 3, 4))
  }

  @Test
  fun contentsReadInAnotherDeclarationAreAnyContainers() {
    val program = program()
    assertTrue(program.readsAnyContainer(summary(slot, readInReader.id, 3), projected = null))
    assertFalse(program.readsAnyContainer(summary(slot, readInMaker.id, 2), projected = null))
  }

  @Test
  fun contentsReadAtAnotherCallThanTheOneThatSteppedInAreAnyContainers() {
    val program = program()
    val read = summary(slot, readInMaker.id, 2)
    assertTrue(program.readsAnyContainer(read, projected = "$FILE:9:1-9:9|"))
    assertFalse(program.readsAnyContainer(read, projected = "${read.at}|"))
  }

  @Test
  fun cellAndHolderAreNotAnyContainerReads() {
    val program = program(cells = listOf(CellFact(list.id, mechanism = "MutableStateFlow")))
    assertFalse(program.readsAnyContainer(summary(slot, readInReader.id, 3), projected = null))
    assertFalse(program().readsAnyContainer(FlowFact(slot, list.id, "heldBy", "$FILE:1:1-1:9"), projected = null))
  }

  @Test
  fun contentsLeaveThroughTheCopyTheyWereEnteredIn() {
    val inCopy = summary(slot, readInMaker.id + "~1", 2)
    val inOtherCopy = summary(slot, readInMaker.id + "~2", 2)
    val callerOnly = summary(slot, readInReader.id, 2)
    val program = program(contextFlows = listOf(inCopy, inOtherCopy, callerOnly))
    val projected = "${inCopy.at}|~1"
    assertNotNull(program.callsAfter(emptyList(), inCopy, projected))
    assertNull(program.callsAfter(emptyList(), inOtherCopy, projected))
    // The copy has no edge to the caller's node, so the call sends the contents there.
    assertNotNull(program.callsAfter(emptyList(), callerOnly, projected))
  }

  @Test
  fun previewsFakesAndTestsAreNotProduction() {
    val preview = function("ScreenPreview")
    val fake = DeclFact("class:app/FakeStore", "class", "FakeStore", null, FILE, "1:1-1:9")
    val fakery = DeclFact("class:app/Fakery", "class", "Fakery", null, FILE, "1:1-1:9")
    val inFake = function("load", owner = fake.sym)
    val inFakery = function("make", owner = fakery.sym)
    val inTest = function("check", file = TEST_FILE)
    val nodes = listOf(preview, inFake, inFakery, inTest, maker).mapIndexed { index, decl -> node(index + 1, "literal", decl) }
    val program =
      Program(
        Facts(
          files = listOf(FileFact(FILE, ":", generated = false), FileFact(TEST_FILE, ":", generated = false, sourceSet = "unitTest")),
          decls = listOf(preview, fake, fakery, inFake, inFakery, inTest, maker),
          annotations = listOf(AnnotationFact(preview.sym, "androidx/compose/ui/tooling/preview/Preview")),
          nodes = nodes,
        ),
        Derived(),
      )
    assertEquals(listOf(true, true, false, true, false), nodes.map { program.isStaged(it.id) })
  }
}
