package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.model.Models
import com.ryanmoelter.altitude.solver.solve
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.Tracer
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Where values go through the library calls of the `models` fixture, one family per section. */
class ModelsTest {
  private companion object {
    val facts: Facts by lazy {
      AltitudeSession.open(AnalysisInput(listOf(Fixture.module("models")))).use(::extractFacts)
    }
    val derived: Derived by lazy { solve(facts) }
    val program: Program by lazy { Program(facts, derived) }
    val tracer: Tracer by lazy { Tracer(program) }
  }

  private fun named(kind: String, name: String): String =
    facts.decls.single { it.kind == kind && it.name == name }.sym

  private fun param(name: String) = named("param", name)

  private fun local(name: String) = named("local", name)

  private fun function(name: String) = named("fun", name)

  private fun reaches(from: String, to: String): Boolean {
    val seen = HashSet(listOf(from))
    val queue = ArrayDeque(listOf(from))
    while (queue.isNotEmpty()) {
      for (edge in program.valueEdges[queue.removeFirst()].orEmpty()) if (seen.add(edge.to)) queue += edge.to
    }
    return to in seen
  }

  /** Lambdas the call of [callee] on [line] of [file] runs, each with its edge kind and role. */
  private fun invoked(file: String, line: Int, callee: String): Map<String, String?> {
    val call = facts.calls.single { it.id.startsWith("models/$file:$line:") && callee in it.target }.id
    return derived.callEdges.filter { it.call == call }.associate { it.via to it.role }
  }

  private fun cell(sym: String) = derived.cells.single { it.sym == sym }

  private fun ops(accesses: List<com.ryanmoelter.altitude.facts.CellAccessFact>, cell: String) =
    accesses.filter { it.cell == cell }.map { it.op }.sorted()

  // Scope functions

  @Test
  fun scopeFunctionsPassTheReceiverInAndTheResultOut() {
    val box = param("box")
    assertTrue(reaches(box, param("seen")), "also passes the receiver as the parameter")
    assertTrue(reaches(box, local("viaApply")), "apply returns the receiver")
    assertTrue(reaches(box, local("viaAlso")), "also returns the receiver")
    val name = "prop:fixture/models/Item.name"
    for (result in listOf("viaLet", "viaRun", "viaWith")) {
      assertTrue(reaches(name, local(result)), "$result is what the lambda returns")
    }
    assertFalse(reaches(name, local("viaApply")), "apply does not return what the lambda does")
  }

  @Test
  fun modelledLambdaIsInvokedAndAnUnmodelledOneIsAssumed() {
    assertEquals(mapOf("invoke" to "block, run once in place"), invoked("Scope.kt", 8, "kotlin/let"))
    assertEquals(mapOf<String, String?>("assumedInvoke" to null), invoked("Scope.kt", 19, "thread"))
    assertEquals(
      listOf("fun:kotlin/concurrent/thread"),
      derived.unmodelledLambdaCalls.map { it.callee.substringBefore('(') },
    )
  }

  @Test
  fun summaryEdgeCarriesItsRule() {
    val edge = derived.flows.single { it.kind == "summary" && it.to == param("seen") }
    assertEquals("kotlin-stdlib.yaml#also", edge.ruleId)
    assertTrue(edge.at.startsWith("models/Scope.kt:10:"))
  }

  // Collections

  @Test
  fun elementsFlowThroughCollectionOperators() {
    val first = param("first")
    assertTrue(reaches(first, param("mapped")), "filter keeps the elements map receives")
    assertTrue(reaches(first, local("found")), "firstOrNull returns an element")
    assertTrue(reaches(first, local("each")), "a for loop reads the elements")
    assertTrue(reaches(first, local("looked")), "associateBy keeps the elements as values")
    assertTrue(reaches(first, local("left")), "a pair is taken apart")
    assertTrue(reaches(param("second"), local("found")))
  }

  @Test
  fun elementsOfOneListDoNotReachAnother() {
    assertTrue(reaches(param("stranger"), local("other")))
    assertFalse(reaches(param("first"), local("other")))
    assertFalse(reaches(param("stranger"), local("found")))
  }

  // Flow operators, StateFlow and SharedFlow

  @Test
  fun backingPropertyIsOneCellWithItsWritesAndReads() {
    val state = cell("prop:fixture/models/Repository._state")
    assertEquals("MutableStateFlow", state.mechanism)
    assertEquals(listOf("initial", "update", "value="), ops(derived.cellWrites, state.id))
    assertEquals(listOf("operator", "update", "value"), ops(derived.cellReads, state.id))
    val names = cell("prop:fixture/models/Repository.names")
    assertEquals("StateFlow by stateIn", names.mechanism)
    assertEquals(listOf("collect"), ops(derived.cellReads, names.id))
  }

  @Test
  fun updateReadsTheOldValueAndWritesTheNew() {
    assertTrue(reaches(param("replacement"), param("old")), "update passes the current value in")
    assertTrue(reaches(param("renamed"), "${function("current")}#<ret>"), "update stores what it returns")
  }

  @Test
  fun operatorChainCarriesValuesIntoStateInAndCollect() {
    assertTrue(reaches(param("replacement"), param("item")))
    assertTrue(reaches("prop:fixture/models/Item.name", param("collected")))
    assertTrue(reaches(param("replacement"), param("collected")), "a name is a member of the item")
    assertFalse(reaches(param("collected"), param("item")), "nothing flows upstream")
  }

  @Test
  fun writingACellRunsItsCollectors() {
    val edges = derived.callEdges.filter { it.via == "cell" && it.caller == function("replace") }
    assertEquals(
      mapOf("value= → map" to 0, "value= → filter" to 1, "value= → collect" to 3),
      edges.associate { it.op.orEmpty() to it.through },
    )
  }

  @Test
  fun sharedFlowJoinsTheEmitterToTheCollector() {
    assertTrue(reaches(param("requested"), param("handled")))
    assertContains(
      tracer.trace("Sync.request", "Sync.handle"),
      "--cell MutableSharedFlow Sync.requests: tryEmit → collect-->",
    )
  }

  // Compose state and delegates

  @Test
  fun rememberedStateIsACellReadAndWrittenThroughBy() {
    val count = cell(local("count"))
    assertEquals("Compose MutableState", count.mechanism)
    assertEquals(listOf("by write", "initial"), ops(derived.cellWrites, count.id))
    assertEquals(listOf("by read"), ops(derived.cellReads, count.id))
    assertTrue(reaches(param("start"), local("shown")))
    assertEquals(
      mapOf("invoke" to "effect, run in a coroutine when the composable enters or a key changes"),
      invoked("State.kt", 15, "LaunchedEffect"),
    )
  }

  @Test
  fun lazyDelegateReturnsWhatItsInitializerDoes() {
    assertTrue(reaches("prop:fixture/models/Config.seed", "${function("read")}#<ret>"))
    assertEquals(mapOf("invoke" to "initializer, run on the first read"), invoked("State.kt", 25, "kotlin/lazy"))
  }

  // The value trace and the model files

  @Test
  fun valueTracePrintsOneHopPerLineWithItsRule() {
    val text = tracer.traceValue("Flows.kt:27:call(value)", "Flows.kt:31:call(collect)")
    assertContains(text, "Shortest path:")
    assertContains(text, "--summary kotlinx-coroutines.yaml#MutableStateFlow.value=-->  cell MutableStateFlow Repository._state")
    assertContains(text, "--memberOf-->")
  }

  @Test
  fun bundledModelsParseAndNameEveryRule() {
    val models = Models.bundled()
    assertTrue(models.entries.size > 100)
    assertEquals("kotlin-stdlib.yaml#let", models.match("fun:kotlin/let@T(kotlin/Function1<T,R>)")?.ruleId)
    assertEquals(
      "kotlinx-coroutines.yaml#combine",
      models.match("fun:kotlinx/coroutines/flow/combine@kotlinx/coroutines/flow/Flow<T1>(x)")?.ruleId,
    )
    assertEquals("kotlinx-coroutines.yaml#combine-n", models.match("fun:kotlinx/coroutines/flow/combine(x)")?.ruleId)
    assertEquals("compose.yaml#composable", models.match("fun:androidx/compose/material3/Button(x)")?.ruleId)
    assertEquals(null, models.match("fun:org/example/unknown()"))
  }
}
