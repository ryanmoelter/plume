package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.solver.expand
import com.ryanmoelter.altitude.solver.withoutContext
import com.ryanmoelter.altitude.trace.TraceOptions
import com.ryanmoelter.altitude.trace.Tracer
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** Value paths that cross calls in the `value` fixture: none that can happen may be dropped. */
class ValueTraceTest {
  private fun assertPath(within: String, from: String = "source", to: String = "sink") =
    assertContains(ValueFixture.trace(within, from, to), "Best path:", message = within)

  @Test
  fun receiverSharedByTwoCallsStillReturns() = assertPath("sharedThis", from = "makeG", to = "sinkG")

  @Test
  fun capturedValueLeavesThroughTheInvoke() = assertPath("capturedThenInvoked")

  @Test
  fun lambdaInvokedAfterItsMakerReturned() = assertPath("escapedLambda")

  @Test
  fun recursionReturns() = assertPath("recursion")

  @Test
  fun callsDeeperThanTheStackReturn() = assertPath("deep")

  @Test
  fun returnGoesToTheCallThePathCameInThrough() {
    assertContains(ValueFixture.trace("twoCallers", nth = 0), "Best path:")
    assertContains(ValueFixture.trace("twoCallers", nth = 1), "No path.")
  }

  @Test
  fun memberCalledFromOutsideReadsWhatTheConstructionPassed() = assertPath("holderCalledFromOutside")

  @Test
  fun memberCalledFromOutsideWritesWhatAnotherReads() = assertPath("holderWrittenFromOutside")

  @Test
  fun callerLambdaRunsOnTheContentsACopiedWrapperReads() =
    assertPath("callerLambdaAfterContentsOfCopiedWrapper", from = "sourceList")

  @Test
  fun wrappersNestedTwoDeepKeepCallersApart() {
    assertContains(ValueFixture.trace("wrappersNestedTwoDeep", nth = 0), "Best path:")
    assertContains(ValueFixture.trace("wrappersNestedTwoDeep", nth = 1), "No path.")
  }

  @Test
  fun wrappersNestedThreeDeepStillReturn() = assertPath("wrappersNestedThreeDeep")

  @Test
  fun wrappersNestedDeeperThanTheyAreCopiedStillReturn() =
    assertPath("wrappersNestedDeeperThanTheyAreCopied")

  @Test
  fun wrapperIsCopiedPerCallSite() {
    val copies = expand(ValueFixture.facts).facts.decls.filter { '~' in it.sym }.map { withoutContext(it.sym) }
    val names = ValueFixture.facts.decls.associate { it.sym to it.name }
    val copiesOf = copies.groupingBy { names[it] }.eachCount()
    // `mapAll` has one call. `w2` has two in `wrappersNestedTwoDeep` and one in `w1`, whose copy
    // for its own call makes another.
    assertEquals(1, copiesOf["mapAll"])
    assertEquals(4, copiesOf["w2"])
  }

  @Test
  fun lambdaReturnedByACopiedWrapperStillRunsItsArgument() = assertPath("lambdaEscapingCopiedWrapper")

  @Test
  fun referenceToAMemberOfACopiedClassRunsTheCopy() = assertPath("referenceToHolderMember")

  @Test
  fun containerReturnedToItsReaderIsThatContainer() {
    val text = ValueFixture.trace("containerReturnedToItsReader")
    assertContains(text, "Best path: 0 any-instance reads")
    assertContains(text, "[the container holding it]")
  }

  @Test
  fun productionRouteOutranksAShorterOneThroughAFake() {
    val text = ValueFixture.trace("fakeOrProduction")
    assertContains(text, "Best path: 0 any-instance reads, 0 hops outside production code")
    assertFalse("FakeRoute" in text.substringAfter("Skeleton:"), text)
  }

  @Test
  fun searchPastItsBudgetSaysItIsIncomplete() {
    val tracer = Tracer(ValueFixture.program, TraceOptions(searchBudget = 3))
    val text = tracer.traceValue(ValueFixture.call("deep", "source"), ValueFixture.call("deep", "sink"))
    assertContains(text, "The search stopped at its budget of 3 steps")
    assertContains(text, "No path found within the budget.")
  }
}
