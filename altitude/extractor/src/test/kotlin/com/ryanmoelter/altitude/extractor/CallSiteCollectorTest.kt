package com.ryanmoelter.altitude.extractor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CallSiteCollectorTest {

  @Test
  fun lambdaWithReceiverResolvesAMemberOfTheReceiver() {
    val call = site("core/common/Draft.kt", Site.CALL, "changeName")
    assertEquals(Target.SOURCE_FUNCTION, call.target)
    assertEquals("fixture/core/Draft.changeName", call.symbol)
  }

  @Test
  fun functionTypedParameterResolvesAsAnInvoke() {
    val call = site("core/common/Draft.kt", Site.CALL, "block")
    assertEquals(Target.VARIABLE_INVOKE, call.target)
    assertEquals("block", call.symbol)
    assertEquals("kotlin/Function1.invoke", call.via)
  }

  @Test
  fun functionTypedPropertyResolvesAsAnInvokeOfTheProperty() {
    val call = site("core/common/Editor.kt", Site.CALL, "edit")
    assertEquals(Target.VARIABLE_INVOKE, call.target)
    assertEquals("fixture/core/Editor.edit", call.symbol)
    assertEquals("kotlin/Function1.invoke", call.via)
  }

  @Test
  fun extensionPropertyResolves() {
    val access = site("core/common/Editor.kt", Site.NAME, "shout")
    assertEquals(Target.SOURCE_PROPERTY, access.target)
    assertEquals("fixture/core/shout", access.symbol)

    val reference = site("core/common/Editor.kt", Site.CALLABLE_REFERENCE, "shout")
    assertEquals(Target.SOURCE_PROPERTY, reference.target)
    assertEquals("fixture/core/shout", reference.symbol)
  }

  @Test
  fun callThroughClassDelegationResolvesToTheInterfaceMember() {
    val call = site("core/common/Delegation.kt", Site.CALL, "greet")
    assertEquals(Target.SOURCE_FUNCTION, call.target)
    assertEquals("fixture/core/Polite.greet", call.symbol)
  }

  @Test
  fun propertyDelegateResolvesItsGetValue() {
    val delegate = site("core/common/Delegation.kt", Site.DELEGATE, "by lazy")
    assertEquals(Target.LIBRARY_FUNCTION, delegate.target)
    assertEquals("kotlin/getValue", delegate.symbol)

    val read = site("core/common/Delegation.kt", Site.NAME, "heavy")
    assertEquals("fixture/core/Config.heavy", read.symbol)
  }

  @Test
  fun callsInCommonCodeResolveToExpectDeclarations() {
    val function = site("core/common/Platform.kt", Site.CALL, "platformName")
    assertEquals(Target.SOURCE_FUNCTION, function.target)
    assertEquals("fixture/core/platformName", function.symbol)

    val constructor = site("core/common/Platform.kt", Site.CALL, "Clock")
    assertEquals(Target.SOURCE_CONSTRUCTOR, constructor.target)

    val member = site("core/common/Platform.kt", Site.CALL, "now")
    assertEquals("fixture/core/Clock.now", member.symbol)
  }

  @Test
  fun infixCallsResolve() {
    val bind = site("core/common/Routes.kt", Site.OPERATOR, "bind")
    assertEquals("fixture/core/bind", bind.symbol)
    val to = site("core/common/Routes.kt", Site.OPERATOR, "to")
    assertEquals("fixture/core/to", to.symbol)
    assertEquals(Target.SOURCE_FUNCTION, to.target)
  }

  @Test
  fun libraryCallsResolve() {
    val map = site("core/common/Flows.kt", Site.CALL, "map")
    assertEquals(Target.LIBRARY_FUNCTION, map.target)
    assertEquals("kotlinx/coroutines/flow/map", map.symbol)

    val first = site("core/common/Flows.kt", Site.CALL, "first")
    assertEquals("kotlin/collections/first", first.symbol)

    val jdk = site("app/App.kt", Site.CALL, "AtomicLong")
    assertEquals(Target.LIBRARY_CONSTRUCTOR, jdk.target)
  }

  @Test
  fun callIntoAnotherSourceModuleResolvesToItsSource() {
    val call = site("app/App.kt", Site.CALL, "rename")
    assertEquals(Target.SOURCE_FUNCTION, call.target)
    assertEquals("fixture/core/rename", call.symbol)
  }

  @Test
  fun missingDeclarationsAreUnresolved() {
    assertEquals(Target.UNRESOLVED, site("app/App.kt", Site.CALL, "missingFunction").target)
    assertEquals(Target.UNRESOLVED, site("app/App.kt", Site.TYPE, "Absent?").target)
    assertEquals(Target.UNRESOLVED, site("app/App.kt", Site.IMPORT, "fixture.missing.Absent").target)
    assertNull(site("app/App.kt", Site.CALL, "missingFunction").symbol)
  }

  @Test
  fun everythingElseInTheFixtureResolves() {
    val unresolved =
      ResolveReport(Fixture.sites).sites.filter { !it.target.resolved }.map { "${it.path} ${it.text}" }
    assertEquals(
      listOf(
        "app/App.kt fixture.missing.Absent",
        "app/App.kt Absent?",
        "app/App.kt missingFunction",
        "app/App.kt +",
        "core/generated/Generated.kt missingInGenerated",
      ),
      unresolved,
    )
  }

  private fun site(file: String, site: Site, text: String): CallSite =
    Fixture.sites.single { it.path == file && it.site == site && it.text == text }
}
