package com.ryanmoelter.altitude.extractor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** What the solver derives for each call shape in the `flow` fixture. */
class FlowSolverTest {
  private val facts = FlowFixture.facts
  private val derived = FlowFixture.derived
  private val program = FlowFixture.program

  /** The call of [dispatch] kind on [line] of `flow/[file]`. */
  private fun call(file: String, line: Int, dispatch: String): String =
    facts.calls.single { it.id.startsWith("flow/$file:$line:") && it.dispatch == dispatch }.id

  /** Callee display names of [call], each with the edge kind that reaches it. */
  private fun edges(call: String): Map<String, String> =
    derived.callEdges.filter { it.call == call }.associate { program.display(it.callee) to it.via }

  private fun fanOut(call: String): Int? = derived.fanOuts.singleOrNull { it.call == call }?.count

  @Test
  fun constructorArgumentReachesTheInvokeThroughARenamedProperty() {
    val invoke = call("Edit.kt", 9, "invokeFnValue")
    assertEquals(
      mapOf("lambda@Edit.kt:38:38" to "fnValue", "lambda@Edit.kt:40:31" to "fnValue"),
      edges(invoke),
    )
    assertEquals(2, fanOut(invoke))
  }

  @Test
  fun memberFunctionNamedLikeItsPropertyInvokesTheProperty() {
    val invoke = call("Edit.kt", 24, "invokeFnValue")
    assertEquals(setOf("lambda@Edit.kt:38:38", "lambda@Edit.kt:40:31"), edges(invoke).keys)
    // `editInGraph(Delta("touched"))` on line 28 is the function, not the property.
    assertEquals(
      mapOf("Graphable.editInGraph(Delta)" to "static", "Delta.<init>(String)" to "static"),
      facts.calls
        .filter { it.id.startsWith("flow/Edit.kt:28:") }
        .flatMap { edges(it.id).entries }
        .associate { it.key to it.value },
    )
  }

  @Test
  fun witnessWalksFromTheLambdaToTheInvoke() {
    val invoke = call("Edit.kt", 24, "invokeFnValue")
    val witness =
      derived.fnValues.single { it.call == invoke && it.value.startsWith("flow/Edit.kt:38:") }.witness
    assertEquals("flow/Edit.kt:38:38-38:72:lambdaExpr", witness.first().from)
    assertTrue(witness.zipWithNext().all { (a, b) -> a.to == b.from }, "the witness is a chain")
    val through = witness.map { it.to }
    for (location in
      listOf(
        "fun:fixture/flow/toGraph(kotlin/Function1<kotlin/collections/List<fixture/flow/Delta>,kotlin/Unit>)#edit",
        "prop:fixture/flow/Graph.edit",
        "prop:fixture/flow/Graph.editInGraph",
        "prop:fixture/flow/Data.editInGraph",
        "prop:fixture/flow/Graphable.editInGraph",
      )) {
      assertTrue(location in through, "the witness passes $location")
    }
  }

  @Test
  fun invokeBindsItsArgumentToTheLambdaParameter() {
    val bound = derived.flows.filter { it.kind == "invokeArg" }.map { it.to }
    assertTrue("flow/Edit.kt:38:38-38:72:lambda#deltas" in bound)
    assertTrue("flow/Edit.kt:40:31-40:33:lambda#it" in bound)
  }

  @Test
  fun lambdaWithReceiverBindsTheReceiver() {
    val extensionForm = call("Receiver.kt", 11, "invokeFnValue")
    val callForm = call("Receiver.kt", 15, "invokeFnValue")
    assertEquals(mapOf("lambda@Receiver.kt:20:15" to "fnValue"), edges(extensionForm))
    assertEquals(mapOf("lambda@Receiver.kt:21:19" to "fnValue"), edges(callForm))
    val receivers = derived.flows.filter { it.kind == "invokeArg" && it.to.endsWith("#<recv>") }
    assertEquals(
      setOf("flow/Receiver.kt:20:15-20:34:lambda#<recv>", "flow/Receiver.kt:21:19-21:37:lambda#<recv>"),
      receivers.map { it.to }.toSet(),
    )
  }

  @Test
  fun interfaceCallDispatchesToEveryImplementation() {
    assertEquals(
      mapOf("FakeSubmitter.submit(String)" to "cha", "RealSubmitter.submit(String)" to "cha"),
      edges(call("Dispatch.kt", 16, "virtual")),
    )
  }

  @Test
  fun classDelegationDispatchesToTheDelegateType() {
    assertEquals(mapOf("English.greet()" to "cha"), edges(call("Dispatch.kt", 33, "virtual")))
    val delegation = facts.supertypes.single { it.viaDelegation }
    assertEquals("class:fixture/flow/Polite", delegation.cls)
    assertEquals("class:fixture/flow/Greeter", delegation.sup)
  }

  @Test
  fun lambdaConvertedToAFunInterfaceIsCalledThroughIt() {
    assertEquals(mapOf("lambda@Dispatch.kt:43:35" to "fnValue"), edges(call("Dispatch.kt", 40, "virtual")))
  }

  @Test
  fun trailingLambdaAndCallableReferenceBothReachTheInvoke() {
    val invoke = call("Args.kt", 11, "invokeFnValue")
    assertEquals(mapOf("lambda@Args.kt:15:47" to "fnValue", "report(String)" to "fnValue"), edges(invoke))
    assertEquals(2, fanOut(invoke))
  }

  @Test
  fun namedAndDefaultArgumentsBindByParameter() {
    val configure = "fun:fixture/flow/configure(kotlin/String,kotlin/Int,kotlin/String...,kotlin/Function1<kotlin/String,kotlin/Unit>)"
    val into = facts.flows.filter { it.to.startsWith("$configure#") }
    assertEquals(
      setOf("default" to "name", "default" to "retries", "arg" to "name", "arg" to "retries", "arg" to "tags", "arg" to "onDone"),
      into.map { it.kind to it.to.substringAfterLast('#') }.toSet(),
    )
    // Line 15 names `retries` and passes the lambda outside the parentheses.
    val named = facts.args.filter { it.call.startsWith("flow/Args.kt:15:") && it.param.startsWith(configure) }
    assertEquals(
      setOf("retries" to "named", "tags" to "named", "onDone" to "trailingLambda"),
      named.map { it.param.substringAfterLast('#') to it.form }.toSet(),
    )
  }

  @Test
  fun localFunctionReferenceReachesTheInvoke() {
    val invoke = call("Args.kt", 22, "invokeFnValue")
    assertEquals(mapOf("helper@Args.kt:20(Int)" to "fnValue"), edges(invoke))
    assertEquals(1, fanOut(invoke))
  }

  @Test
  fun lambdaStoredInAPropertyReachesASafeInvoke() {
    assertEquals(mapOf("lambda@Args.kt:38:21" to "fnValue"), edges(call("Args.kt", 33, "invokeFnValue")))
  }

  @Test
  fun lambdaPassedToALibraryFunctionIsAssumedInvoked() {
    val forEach = facts.calls.single { it.target.startsWith("fun:kotlin/collections/forEach") }.id
    assertEquals(mapOf("lambda@Args.kt:26:18" to "assumedInvoke"), edges(forEach))
    assertEquals(
      listOf("fun:kotlin/collections/forEach"),
      facts.unmodelledLambdaCalls.filter { it.call == forEach }.map { it.callee.substringBefore('@') },
    )
  }

  @Test
  fun everyFunctionValueInvokeHasAFanOutRow() {
    val invokes = facts.calls.filter { it.dispatch == "invokeFnValue" }.map { it.id }.toSet()
    assertEquals(invokes, derived.fanOuts.map { it.call }.toSet())
    assertTrue(derived.fanOuts.none { it.count == 0 }, "the fixture has no dead invoke")
  }
}
