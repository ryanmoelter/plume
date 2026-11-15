package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.FactStore
import java.nio.file.Path
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** The relations are documented in `altitude/docs/rules.md`. */
@Serializable
data class BindingFact(
  val framework: String,
  val graph: String,
  val type: String,
  val qualifier: String? = null,
  val provider: String,
  val kind: String,
  val scope: String? = null,
  val reachable: Boolean,
  val multibinding: String? = null,
  val mapKey: String? = null,
  /** The constructor an assisted factory calls. */
  val assistedTarget: String? = null,
  /** The graph or component a `parentGraph` or `parentComponent` row takes the binding from. */
  val parent: String? = null,
  val variant: String,
  val confidence: String? = null,
  val note: String? = null,
  /** The rule that made the row, such as `M6`. */
  val evidence: String? = null,
  val file: String? = null,
  val line: Int? = null,
)

@Serializable
data class InjectionSiteFact(
  val framework: String,
  val graph: String,
  val site: String,
  val type: String,
  val qualifier: String? = null,
  val wrapper: String,
  /** One provider ID, or a list when the site takes every element of a multibinding. */
  val provider: JsonElement? = null,
  val typeKind: String,
  val variant: String,
  val note: String? = null,
  val file: String? = null,
  val line: Int? = null,
) {
  val providers: List<String>
    get() =
      when (provider) {
        is JsonArray -> provider.map { (it as JsonPrimitive).content }
        is JsonPrimitive -> listOf(provider.content)
        else -> emptyList()
      }

  companion object {
    fun providerOf(providers: List<String>): JsonElement? =
      when (providers.size) {
        0 -> null
        1 -> JsonPrimitive(providers.single())
        else -> JsonArray(providers.map(::JsonPrimitive))
      }
  }
}

@Serializable
data class DiUnresolvedFact(
  val framework: String,
  val graph: String? = null,
  /** The consumer, or the declaration the rule could not decide. */
  val site: String,
  val type: String? = null,
  val qualifier: String? = null,
  /** A reason code; `docs/rules.md` lists them. */
  val reason: String,
  val detail: String? = null,
  val file: String? = null,
  val line: Int? = null,
)

@Serializable
data class RouteFact(
  val method: String,
  val path: String,
  val handler: String,
  /** Outermost first. No default, so a route without filters still writes `[]`. */
  val filters: List<String>,
  val mounted: Boolean = true,
  val confidence: String? = null,
  val note: String? = null,
  val file: String,
  val line: Int,
)

@Serializable
data class ResolverFact(
  val kind: String,
  val type: String,
  val field: String,
  val decl: String,
  /** `<file>:<line>` of the `register` call of a DataLoader. */
  val registeredAt: String? = null,
  val file: String,
  val line: Int,
)

@Serializable
data class ScreenFact(
  @SerialName("class") val cls: String,
  val kind: String,
  val content: String? = null,
  val lifecycle: List<String> = emptyList(),
  val note: String? = null,
  val file: String,
  val line: Int,
)

/** One row per way control enters the program; the union of the route, resolver and screen rows. */
@Serializable
data class EntrypointFact(
  /** `httpRoute`, `graphqlResolver`, `composableContent`, `lifecycleHook` or `main`. */
  val kind: String,
  val sym: String,
  val attrs: Map<String, String> = emptyMap(),
  val file: String? = null,
  val line: Int? = null,
)

@Serializable
data class BoundaryFact(
  val system: String,
  /** `sqlRead`, `sqlWrite`, `apolloQuery`, `apolloMutation`, `apolloSubscription`, `httpOut`, `retrofit`, `revenuecat`, `posthog` or `sentry`. */
  val kind: String,
  val op: String,
  val target: String,
  val caller: String,
  val call: String,
  val access: String? = null,
  val label: String? = null,
  val sq: String? = null,
  val operation: String? = null,
  val via: String? = null,
  val method: String? = null,
  val path: String? = null,
  val client: String? = null,
  val note: String? = null,
  val file: String,
  val line: Int,
)

@Serializable
data class NavigationFact(
  val from: String,
  /** The destination class; absent for a call that only pops, or whose destination is unknown. */
  val to: String? = null,
  val call: String,
  /** The navigator function: `goTo`, `replace` and the like. */
  val op: String,
  val file: String,
  val line: Int,
)

/** What the rules derive. */
data class Rules(
  val bindings: List<BindingFact> = emptyList(),
  val injectionSites: List<InjectionSiteFact> = emptyList(),
  val diUnresolved: List<DiUnresolvedFact> = emptyList(),
  val routes: List<RouteFact> = emptyList(),
  val resolvers: List<ResolverFact> = emptyList(),
  val screens: List<ScreenFact> = emptyList(),
  val entrypoints: List<EntrypointFact> = emptyList(),
  val boundaries: List<BoundaryFact> = emptyList(),
  val navigations: List<NavigationFact> = emptyList(),
) {
  fun write(dir: Path) {
    FactStore.writeRelation(dir, "binding", BindingFact.serializer(), bindings)
    FactStore.writeRelation(dir, "injectionSite", InjectionSiteFact.serializer(), injectionSites)
    FactStore.writeRelation(dir, "diUnresolved", DiUnresolvedFact.serializer(), diUnresolved)
    FactStore.writeRelation(dir, "route", RouteFact.serializer(), routes)
    FactStore.writeRelation(dir, "resolver", ResolverFact.serializer(), resolvers)
    FactStore.writeRelation(dir, "screen", ScreenFact.serializer(), screens)
    FactStore.writeRelation(dir, "entrypoint", EntrypointFact.serializer(), entrypoints)
    FactStore.writeRelation(dir, "boundary", BoundaryFact.serializer(), boundaries)
    FactStore.writeRelation(dir, "navigation", NavigationFact.serializer(), navigations)
  }

  companion object {
    fun read(dir: Path): Rules =
      Rules(
        bindings = FactStore.readRelation(dir, "binding", BindingFact.serializer()),
        injectionSites = FactStore.readRelation(dir, "injectionSite", InjectionSiteFact.serializer()),
        diUnresolved = FactStore.readRelation(dir, "diUnresolved", DiUnresolvedFact.serializer()),
        routes = FactStore.readRelation(dir, "route", RouteFact.serializer()),
        resolvers = FactStore.readRelation(dir, "resolver", ResolverFact.serializer()),
        screens = FactStore.readRelation(dir, "screen", ScreenFact.serializer()),
        entrypoints = FactStore.readRelation(dir, "entrypoint", EntrypointFact.serializer()),
        boundaries = FactStore.readRelation(dir, "boundary", BoundaryFact.serializer()),
        navigations = FactStore.readRelation(dir, "navigation", NavigationFact.serializer()),
      )
  }
}
