package com.ryanmoelter.altitude.extractor

import kotlin.test.Test
import kotlin.test.assertContains

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
}
