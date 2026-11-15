package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.rules.analyze
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * `fixture/di` compiled against the real Metro and kotlin-inject runtimes: a Metro graph with a
 * provider, a `@Binds` receiver property and a `Lazy` site, and a kotlin-inject child component that
 * resolves through its parent and asks for a function of an assisted injectable.
 */
class DiFixtureTest {
  private val analysis by lazy {
    analyze(AltitudeSession.open(AnalysisInput(listOf(Fixture.module("di")))).use(::extractFacts))
  }

  private val metro = "fixture/di/metro"
  private val inject = "fixture/di/inject"
  private val presenter = "ctor:$metro/Presenter($metro/Repo,kotlin/Lazy<$metro/Api>)"
  private val greeter = "ctor:$inject/Greeter($inject/Clock,kotlin/Function1<kotlin/String,$inject/Label>)"

  @Test
  fun bindings() {
    val rows = analysis.rules.bindings.map { listOf(it.graph, it.type, it.provider, it.kind, it.reachable.toString(), it.parent) }
    assertEquals(
      listOf(
        listOf("fixture.di.metro.AppGraph", "fixture.di.metro.Api", "fun:$metro/AppGraph.api()", "provides", "true", null),
        listOf("fixture.di.metro.AppGraph", "fixture.di.metro.AppGraph", "class:$metro/AppGraph", "graph", "false", null),
        listOf("fixture.di.metro.AppGraph", "fixture.di.metro.Presenter", presenter, "constructorInject", "true", null),
        listOf("fixture.di.metro.AppGraph", "fixture.di.metro.RealRepo", "ctor:$metro/RealRepo($metro/Api)", "constructorInject", "true", null),
        listOf("fixture.di.metro.AppGraph", "fixture.di.metro.Repo", "prop:$metro/AppGraph.bind@$metro/RealRepo", "binds", "true", null),
        listOf("fixture.di.metro.AppGraph", "fixture.di.metro.Unused", "fun:$metro/AppGraph.unused()", "provides", "false", null),
        listOf(
          "fixture.di.inject.ChildComponent",
          "fixture.di.inject.Clock",
          "prop:$inject/ParentComponent.clock",
          "parentComponent",
          "true",
          "fixture.di.inject.ParentComponent",
        ),
        listOf("fixture.di.inject.ChildComponent", "fixture.di.inject.Greeter", greeter, "constructorInject", "true", null),
        listOf("fixture.di.inject.ChildComponent", "fixture.di.inject.Label", "ctor:$inject/Label(kotlin/String,$inject/Clock)", "constructorInject", "true", null),
        listOf("fixture.di.inject.ParentComponent", "fixture.di.inject.Clock", "fun:$inject/ParentComponent.clock()", "provides", "true", null),
      ),
      rows,
    )
    assertEquals(emptyList(), analysis.rules.diUnresolved)
  }

  @Test
  fun sitesNameTheirWrapper() {
    val wrappers = analysis.rules.injectionSites.associate { it.site to it.wrapper }
    assertEquals("lazy", wrappers["$presenter#api"])
    assertEquals("direct", wrappers["$presenter#repo"])
    assertEquals("function", wrappers["$greeter#label"])
  }

  @Test
  fun accessorCallsReachTheirProviders() {
    val edges = analysis.derived.callEdges.filter { it.via == "di" }.map { it.caller to it.callee }
    assertEquals(listOf("fun:$inject/run($inject/ChildComponent)" to greeter, "fun:$metro/main()" to presenter), edges)
  }

  @Test
  fun providedValuesFlowToTheirSites() {
    val flows = analysis.derived.flows.filter { it.kind == "di" }.map { it.from to it.to }
    assertTrue("fun:$metro/AppGraph.api()#<ret>" to "ctor:$metro/RealRepo($metro/Api)#api" in flows)
    assertTrue("prop:$metro/AppGraph.bind@$metro/RealRepo#<recv>" to "$presenter#repo" in flows)
    assertTrue("fun:$inject/ParentComponent.clock()#<ret>" to "$greeter#clock" in flows)
  }
}
