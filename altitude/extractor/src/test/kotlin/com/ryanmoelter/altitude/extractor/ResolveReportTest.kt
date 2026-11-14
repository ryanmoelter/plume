package com.ryanmoelter.altitude.extractor

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class ResolveReportTest {
  private val report = ResolveReport(Fixture.sites)

  @Test
  fun splitsHandWrittenFromGenerated() {
    assertEquals(Ratio(1, 0), report.callLikeResolved(generated = true))
    val handWritten = report.callLikeResolved()
    assertEquals(2, handWritten.total - handWritten.resolved)
    assertEquals(handWritten, sumOf(":app", ":core"))
  }

  @Test
  fun listsUnresolvedSitesWithRelativeLocations() {
    assertContains(report.text(), "     1  call missingFunction  [UNRESOLVED_REFERENCE]")
    assertContains(report.text(), "          app/App.kt:11:10")
    assertContains(
      report.unresolvedJsonl(),
      """{"path":"core/generated/Generated.kt","line":3,"column":28,"module":":core",""" +
        """"generated":true,"site":"CALL","text":"missingInGenerated","target":"UNRESOLVED",""" +
        """"diagnostic":"UNRESOLVED_REFERENCE"}""",
    )
  }

  @Test
  fun outputIsIdenticalAcrossSessionsAndHoldsNoAbsolutePath() {
    val again = ResolveReport(AltitudeSession.open(Fixture.input).use(::collectCallSites))
    assertEquals(report.text(), again.text())
    assertEquals(report.unresolvedJsonl(), again.unresolvedJsonl())
    val home = System.getProperty("user.home")
    assertFalse(home in report.text() || home in report.unresolvedJsonl())
  }

  private fun sumOf(vararg modules: String): Ratio =
    modules
      .map { report.callLikeResolved(module = it) }
      .reduce { a, b -> Ratio(a.total + b.total, a.resolved + b.resolved) }
}
