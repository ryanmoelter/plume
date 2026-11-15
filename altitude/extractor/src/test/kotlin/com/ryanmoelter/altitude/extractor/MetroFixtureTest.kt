package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.PluginOptionFact
import com.ryanmoelter.altitude.rules.Analysis
import com.ryanmoelter.altitude.rules.BindingFact
import com.ryanmoelter.altitude.rules.DiUnresolvedFact
import com.ryanmoelter.altitude.rules.InjectionSiteFact
import com.ryanmoelter.altitude.rules.analyze
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The Metro features of `docs/di/metro.md`'s support table, each in its own package of
 * `fixture/di/metro`: multibindings and their wrapped values, `priority`/`replaces`/`excludes`,
 * scoped classes in graph extensions, `ExposeImplBinding`, the rest of the feature sweep, and the
 * `diUnresolved` row each graph Metro would reject gets.
 */
class MetroFixtureTest {
  companion object {
    private val facts: Facts by lazy {
      AltitudeSession.open(AnalysisInput(listOf(Fixture.module("di")))).use(::extractFacts)
    }

    private val analysis: Analysis by lazy { analyze(facts) }

    private fun withOptions(vararg options: Pair<String, String>): Analysis =
      analyze(facts.copy(pluginOptions = options.map { (key, value) -> PluginOptionFact(":di", "dev.zacsweers.metro.compiler", key, value) }))

    private val optioned: Analysis by lazy {
      withOptions("generate-contribution-providers" to "true", "enable-top-level-function-injection" to "true")
    }
  }

  private val root = "fixture/di/metro"

  private fun Analysis.bindings(pkg: String): List<BindingFact> =
    rules.bindings.filter { it.graph.startsWith("fixture.di.metro.$pkg.") }

  private fun Analysis.sites(pkg: String): Map<String, InjectionSiteFact> =
    rules.injectionSites.filter { it.graph.startsWith("fixture.di.metro.$pkg.") }.associateBy { it.site.substringAfterLast('#') }

  private fun Analysis.unresolved(pkg: String): List<List<String?>> =
    rules.diUnresolved
      .filter { (it.graph ?: "").startsWith("fixture.di.metro.$pkg.") || it.site.contains("$root/$pkg/") }
      .map { listOf(it.graph?.substringAfterLast('.'), it.site.substringAfter(":").replace("$root/", ""), it.reason) }

  private fun row(site: InjectionSiteFact?): List<Any?> = listOf(site?.type, site?.wrapper, site?.providers)

  @Test
  fun mapValueWrappersLinkToEveryEntry() {
    val sites = analysis.sites("multibind")
    val pkg = "fixture.di.metro.multibind"
    val entries = listOf("ctor:$root/multibind/PluginA()", "fun:$root/multibind/MultiGraph.provideP()")
    val map = "kotlin.collections.Map<kotlin.String, $pkg.Plugin>"
    assertEquals(listOf(map, "direct", entries), row(sites["direct"]))
    assertEquals(listOf(map, "provider", entries), row(sites["providers"]))
    assertEquals(listOf(map, "function", entries), row(sites["functions"]))
    assertEquals(listOf(map, "lazy", entries), row(sites["lazies"]))
    assertEquals(listOf(map, "providerOfLazy", entries), row(sites["providerOfLazies"]))
    assertEquals(listOf(map, "provider", entries), row(sites["providedMap"]))
    assertEquals(listOf("ctor:$root/multibind/PluginB()"), sites["byClass"]?.providers)
    assertEquals(listOf("ctor:$root/multibind/SetPlugin()"), sites["set"]?.providers)
    assertEquals(listOf("fun:$root/multibind/MultiGraph.ints()", "fun:$root/multibind/MultiGraph.one()"), sites["ints"]?.providers)
    assertEquals(listOf("prop:$root/multibind/MultiGraph.empty"), sites["empty"]?.providers)
    assertEquals(emptyList(), analysis.unresolved("multibind"))
  }

  @Test
  fun mapKeysTakeTheirTypeFromTheKeyAnnotation() {
    val keys = analysis.bindings("multibind").filter { it.multibinding == "map" }.associate { it.provider.substringAfterLast('/') to (it.type to it.mapKey) }
    val pkg = "fixture.di.metro.multibind"
    // ClassKey without a value names the class it annotates.
    assertEquals("kotlin.collections.Map<kotlin.reflect.KClass<*>, $pkg.Plugin>" to "$pkg.PluginB", keys["PluginB()"])
    assertEquals("kotlin.collections.Map<$pkg.Color, kotlin.Int>" to "enumEntry:$root/multibind/Color.RED", keys["MultiGraph.red()"])
    assertEquals("kotlin.collections.Map<$pkg.PairKey, kotlin.Int>" to "$pkg.PairKey(\"x\", enumEntry:$root/multibind/Color.RED)", keys["MultiGraph.pair()"])
  }

  @Test
  fun priorityReplacesAndExcludesPickOneContribution() {
    val sites = analysis.sites("priority")
    val pkg = "$root/priority"
    assertEquals(listOf("ctor:$pkg/HighStore()"), sites["store"]?.providers)
    assertEquals(listOf("ctor:$pkg/NewCache()"), sites["cache"]?.providers)
    assertEquals(listOf("ctor:$pkg/SystemClock()"), sites["clock"]?.providers)
    assertEquals(listOf("ctor:$pkg/HighHandler()", "ctor:$pkg/OtherHandler()"), sites["handlers"]?.providers)
    // `replaces` acts only in a graph that receives the replacing contribution.
    val other = analysis.rules.injectionSites.single { it.graph == "fixture.di.metro.priority.OtherGraph" }
    assertEquals(listOf("ctor:$pkg/OldCache()"), other.providers)
    assertEquals(listOf(listOf("PriorityGraph", "priority/Uses(priority/Store,priority/Cache,priority/Clock,kotlin/collections/Map<kotlin/String,priority/Handler>,priority/Logger)#logger", "duplicateBinding")), analysis.unresolved("priority"))
  }

  @Test
  fun scopedClassResolvesInTheGraphOwningItsScope() {
    val rows = analysis.bindings("extension").filter { it.type.endsWith("Session") || it.type.endsWith("Screen") }.map { listOf(it.graph.substringAfterLast('.'), it.type.substringAfterLast('.'), it.kind, it.parent?.substringAfterLast('.')) }
    assertEquals(
      listOf(
        listOf("ChildGraph", "Screen", "constructorInject", null),
        listOf("ChildGraph", "Session", "parentGraph", "ParentGraph"),
        listOf("ParentGraph", "Session", "constructorInject", null),
      ),
      rows,
    )
    assertEquals(emptyList(), analysis.unresolved("extension"))
  }

  @Test
  fun exposeImplBindingKeepsTheImplementationInjectable() {
    assertEquals(emptyList(), analysis.unresolved("expose"))
    val sites = optioned.sites("expose")
    assertEquals(listOf("ctor:$root/expose/RealPrefs()"), sites["prefs"]?.providers)
    assertEquals(listOf("ctor:$root/expose/RealTokens()"), sites["t"]?.providers)
    assertEquals(emptyList(), sites["tokens"]?.providers)
    val hidden = optioned.rules.diUnresolved.single { it.graph == "fixture.di.metro.expose.ExposeGraph" }
    assertEquals("missingBinding", hidden.reason)
    assertEquals(
      "generate-contribution-providers hides the implementation type; inject its bound type or add @ExposeImplBinding",
      hidden.detail,
    )
  }

  @Test
  fun featureSweepLinksEverySite() {
    val sites = analysis.sites("features")
    val pkg = "$root/features"
    val engine = "prop:$pkg/FeatureGraph.bind@$pkg/RealEngine"
    assertEquals(listOf("fixture.di.metro.features.Engine", "provider", listOf(engine)), row(sites["engine"]))
    assertEquals(listOf("fixture.di.metro.features.Engine", "lazy", listOf(engine)), row(sites["lazyEngine"]))
    assertEquals(listOf("fixture.di.metro.features.Engine", "function", listOf(engine)), row(sites["nested"]))
    assertEquals("assistedFactory", sites["factory"]?.wrapper)
    assertEquals(listOf("class:$pkg/Target"), sites["injector"]?.providers)
    assertEquals(listOf("fun:$pkg/FeatureGraph.scoped()"), sites["scoped"]?.providers)
    assertEquals("default value", sites["optional"]?.note)
    assertEquals(listOf("fun:$pkg/OuterContainer.outer()"), sites["short"]?.providers)
    assertEquals(listOf("fun:$pkg/InnerContainer.inner()"), sites["byte"]?.providers)
    assertEquals(listOf("fun:$pkg/Contributed.provideContributed()"), sites["contributed"]?.providers)
    assertEquals(listOf("prop:$pkg/Remote.port"), sites["port"]?.providers)
    // `DefaultBinding<Animal>` on `Pet` makes `Dog : Pet, Comparable<Dog>` bind as `Animal`.
    assertEquals(listOf("ctor:$pkg/Dog()"), sites["animal"]?.providers)
    assertEquals(listOf("fun:$pkg/FeatureGraph.base()"), sites["base"]?.providers)
    assertEquals(
      listOf(
        listOf(null, "features/Greeting(kotlin/String,kotlin/String)", "unsupportedFeature"),
        // `GraphPrivate` hides `hidden()` from the extension.
        listOf("LeafGraph", "features/LeafGraph.hidden", "missingBinding"),
      ),
      analysis.unresolved("features"),
    )
    val extension = analysis.bindings("features").filter { it.kind.startsWith("graphExtension") }.map { it.type.substringAfterLast("features.") }
    assertEquals(listOf("LeafGraph", "LeafGraph.Factory"), extension)
  }

  @Test
  fun topLevelFunctionInjectionBindsTheGeneratedClass() {
    val greeting = optioned.rules.bindings.filter { it.kind == "functionInject" }.map { it.graph to it.type }.toSet()
    assertEquals(
      setOf(
        "fixture.di.metro.features.FeatureGraph" to "fixture.di.metro.features.Greeting",
        "fixture.di.metro.features.LeafGraph" to "fixture.di.metro.features.Greeting",
      ),
      greeting.filter { it.first.startsWith("fixture.di.metro.features.") }.toSet(),
    )
  }

  @Test
  fun graphsMetroWouldRejectGetARow() {
    val rows = analysis.rules.diUnresolved.filter { it.graph == "fixture.di.metro.diagnostics.DiagGraph" }
    assertEquals(
      listOf(
        "class:$root/diagnostics/AbstractService" to "notInjectable",
        "class:$root/diagnostics/TwoConstructors" to "notInjectable",
        "class:$root/diagnostics/TwoFaces" to "ambiguousBoundType",
        "class:$root/diagnostics/Unkeyed" to "missingMapKey",
        "ctor:$root/diagnostics/Misscoped()" to "scopeMismatch",
        "di/metro/diagnostics/Diagnostics.kt:42:28-42:64:call" to "unsupportedFeature",
        "prop:$root/diagnostics/DiagGraph.keyed" to "missingBinding",
        "prop:$root/diagnostics/DiagGraph.nothing" to "emptyMultibinding",
        "prop:$root/diagnostics/DiagGraph.service" to "missingBinding",
      ),
      rows.map(DiUnresolvedFact::site).zip(rows.map(DiUnresolvedFact::reason)),
    )
    assertEquals(true, rows.all { it.detail != null || it.reason == "missingBinding" })
  }

  @Test
  fun interopOptionMakesForeignInjectCount() {
    assertEquals(listOf(listOf("InteropGraph", "interop/InteropGraph.foreign", "missingBinding")), analysis.unresolved("interop"))
    val interop = withOptions("interop-include-kotlin-inject-annotations" to "true")
    assertEquals(listOf("ctor:$root/interop/Foreign()"), interop.sites("interop")["prop:$root/interop/InteropGraph.foreign"]?.providers)
    assertEquals(emptyList(), interop.unresolved("interop"))
  }

  @Test
  fun aDefaultValueWithoutOptionalBindingIsRequiredUnderStricterModes() {
    for (mode in listOf("REQUIRE_OPTIONAL_BINDING", "DISABLED")) {
      val missing = withOptions("optional-binding-behavior" to mode).rules.diUnresolved.filter { it.site.endsWith("#optional") }
      assertEquals(listOf("FeatureGraph" to "missingBinding", "LeafGraph" to "missingBinding"), missing.map { it.graph?.substringAfterLast('.') to it.reason }, mode)
    }
  }

  @Test
  fun suspendWrappersCountOnlyWithTheirOption() {
    val engine = "fixture.di.metro.suspending.Engine"
    val linked = listOf("ctor:$root/suspending/Engine()")
    val on = withOptions("enable-suspend-providers" to "true").sites("suspending")
    assertEquals(listOf(engine, "provider", linked), row(on["provided"]))
    assertEquals(listOf(engine, "lazy", linked), row(on["lazy"]))
    assertEquals(listOf(engine, "function", linked), row(on["function"]))
    assertEquals(listOf("missingBinding", "missingBinding", "missingBinding"), analysis.unresolved("suspending").map { it[2] })
  }

  @Test
  fun twoEntriesWithOneMapKeyAreADuplicate() {
    val dup = analysis.rules.diUnresolved.filter { it.graph == "fixture.di.metro.diagnostics.DupGraph" }
    val graph = "$root/diagnostics/DupGraph"
    assertEquals(listOf("fun:$graph.first()" to "duplicateMapKey"), dup.map { it.site to it.reason })
    assertEquals("map key \"a\" is bound by fun:$graph.first(),fun:$graph.second()", dup.single().detail)
  }
}
