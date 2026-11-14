package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.trace.TraceOptions
import com.ryanmoelter.altitude.trace.Tracer
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals

class TraceTest {
  private val tracer = FlowFixture.tracer

  @Test
  fun pathCrossesTheFunctionValueInvoke() {
    val text = tracer.trace("Item.touch", "Queue.submit")
    assertContains(text, "Paths: 1 within 30 hops.")
    assertContains(text, "== Shortest path (3 hops) ==")
    assertContains(
      text,
      "flow/Edit.kt:28  Item.touch()  --call [static]-->  Graphable.editInGraph(Delta)",
    )
    assertContains(
      text,
      "flow/Edit.kt:24  Graphable.editInGraph(Delta)  --call [via fnValue, fan-out 2]-->  lambda@Edit.kt:38",
    )
    assertContains(text, "the value reaches the invoke over")
    assertContains(
      text,
      "flow/Edit.kt:38  lambda@Edit.kt:38  --call [static]-->  Queue.submit(List<Delta>)",
    )
  }

  @Test
  fun chaHopNamesItsCandidateCount() {
    assertContains(
      tracer.trace("Sync.run", "RealSubmitter.submit"),
      "flow/Dispatch.kt:16  Sync.run()  --call [via cha, 2 candidates]-->  RealSubmitter.submit(String)",
    )
  }

  @Test
  fun assumedInvokeIsNamedInTheHop() {
    assertContains(
      tracer.trace("eachReported", "report"),
      "--assumedInvoke [lambda passed to kotlin/collections/forEach [library]]-->  lambda@Args.kt:26",
    )
  }

  @Test
  fun ambiguousSelectorListsItsCandidates() {
    val text = tracer.trace("submit", "report")
    assertContains(text, "--from submit: 4 declarations match; pass one symbol ID:")
    assertContains(text, "=  fun:fixture/flow/Queue.submit(kotlin/collections/List)")
  }

  @Test
  fun missingPathSaysSo() {
    assertContains(tracer.trace("report", "Queue.submit"), "No path within 30 hops.")
  }

  @Test
  fun alternatesBeyondTheLimitAreCounted() {
    val text = Tracer(FlowFixture.program, TraceOptions(alternates = 0)).trace("useConfigure", "report")
    assertContains(text, "Paths: 2 within 30 hops.")
    assertContains(text, "Showing the shortest and 0 alternates; 1 more are not printed.")
  }

  @Test
  fun libraryGoalEndsOnTheBoundaryCall() {
    assertContains(
      tracer.trace("eachReported", "kotlin.Int.toString"),
      "flow/Args.kt:26  lambda@Args.kt:26  --call [library]-->  kotlin/Int.toString [library]",
    )
  }

  @Test
  fun forwardListsLibraryCallsAndDeadInvokes() {
    val text = tracer.forward("Graph.rename")
    assertContains(text, "0 function-value invokes in those declarations have no known target")
    assertContains(text, "kotlin/collections/listOf [library]  (depth 1)")
  }

  @Test
  fun traceIsStable() {
    assertEquals(tracer.trace("Item.touch", "Queue.submit"), tracer.trace("Item.touch", "Queue.submit"))
  }
}
