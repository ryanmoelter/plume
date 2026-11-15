package com.ryanmoelter.altitude.rules

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

private const val BIND_METHOD = "fun:org/http4k/routing/bind@kotlin/String(org/http4k/core/Method)"
private const val BIND_HANDLER = "fun:org/http4k/routing/bind@kotlin/String(org/http4k/routing/RoutingHttpHandler)"
private const val TO = "fun:org/http4k/routing/PathMethod.to(kotlin/Function1<org/http4k/core/Request,org/http4k/core/Response>)"
private const val ROUTES = "fun:org/http4k/routing/routes(org/http4k/routing/RoutingHttpHandler...)"
private const val THEN = "fun:org/http4k/core/then@org/http4k/core/Filter(org/http4k/routing/RoutingHttpHandler)"
private const val AS_SERVER = "fun:org/http4k/server/asServer@kotlin/Function1<org/http4k/core/Request,org/http4k/core/Response>(org/http4k/server/ServerConfig)"
private const val MAGELLAN = "class:com/ryanmoelter/magellanx"

class EntrypointRulesTest {
  /**
   * `authFilter.then(routes("/a" bind routes("/b/" bind GET to {}))).asServer(...)`, and a second
   * tree that only a function returns.
   */
  @Test
  fun routesJoinPathsAndFiltersFromTheServerRoot() {
    val facts = FactsBuilder()
    fun leaf(line: Int, path: String): String {
      val method = facts.node(line, "propRef", target = "enumEntry:org/http4k/core/Method.GET")
      val bound = facts.call(line, BIND_METHOD, listOf(method), extReceiver = facts.literal(line, path))
      return facts.call(line + 1, TO, listOf(facts.node(line + 1, "lambdaExpr", target = facts.position(line + 1, "lambda"))), receiver = bound)
    }
    val inner = facts.call(12, ROUTES, listOf(leaf(10, "/b/")), form = "vararg")
    val mount = facts.call(14, BIND_HANDLER, listOf(inner), extReceiver = facts.literal(14, "/a"))
    val tree = facts.call(16, ROUTES, listOf(mount), form = "vararg")
    val filter = facts.node(18, "propRef", target = facts.decl("prop:app/authFilter", "prop"))
    facts.call(22, AS_SERVER, extReceiver = facts.call(20, THEN, listOf(tree), extReceiver = filter))
    facts.decl("fun:app/unused()", "fun")
    facts.flow(facts.call(32, ROUTES, listOf(leaf(30, "/c")), form = "vararg"), "fun:app/unused()#<ret>")

    val routes = deriveRoutes(facts.index, facts.noDerived)

    assertEquals(listOf("/a/b" to true, "/c" to false), routes.map { it.path to it.mounted })
    val mounted = routes.first()
    assertEquals("GET", mounted.method)
    assertEquals(facts.position(11, "lambda"), mounted.handler)
    assertEquals(listOf("prop:app/authFilter"), mounted.filters)
    assertEquals(10, mounted.line)
    assertEquals(emptyList(), routes.last().filters)
  }

  /** A branch of `routes(listOf(a) + if (x) emptyList() else listOf(b))` is unsure. */
  @Test
  fun aConditionalRouteIsUnsure() {
    val facts = FactsBuilder()
    val always = facts.call(1, "fun:app/lib/always()")
    val sometimes = facts.call(2, "fun:app/lib/sometimes()")
    val base = facts.call(3, "fun:kotlin/collections/listOf(T...)", listOf(always), form = "vararg")
    val empty = facts.call(4, "fun:kotlin/collections/emptyList()")
    val extra = facts.call(5, "fun:kotlin/collections/listOf(T)", listOf(sometimes))
    val all = facts.call(6, "fun:kotlin/collections/plus@kotlin/collections/Collection<T>(kotlin/collections/Iterable<T>)", listOf(empty, extra), extReceiver = base)
    facts.call(7, "fun:org/http4k/routing/routes(kotlin/collections/List<org/http4k/routing/RoutingHttpHandler>)", listOf(all))

    val routes = deriveRoutes(facts.index, facts.noDerived)

    assertEquals(listOf("fun:app/lib/always()" to null, "fun:app/lib/sometimes()" to "unsure"), routes.map { it.handler to it.confidence })
    assertEquals(listOf("ANY", "ANY"), routes.map { it.method })
    assertEquals(listOf("/", "/"), routes.map { it.path })
  }

  @Test
  fun resolversComeFromSchemaRootsAndTheTypesTheyReturn() {
    val facts = FactsBuilder()
    facts.decl("class:app/Queries", "class")
    facts.decl("fun:app/Queries.thing()", "fun", line = 3, type = "kotlin.collections.List<app.schema.Thing?>", owner = "class:app/Queries")
    facts.decl("fun:app/Queries.helper()", "fun", type = "app.schema.Hidden", modifiers = listOf("private"), owner = "class:app/Queries")
    facts.decl("class:app/schema/Thing", "class")
    facts.decl("fun:app/schema/Thing.owner()", "fun", line = 5, type = "app.schema.Id", owner = "class:app/schema/Thing")
    facts.decl("class:app/schema/Id", "class", modifiers = listOf("value"))
    facts.decl("fun:app/schema/Id.asLong()", "fun", type = "kotlin.Long", owner = "class:app/schema/Id")
    facts.decl("class:app/schema/Hidden", "class")
    facts.decl("fun:app/schema/Hidden.secret()", "fun", type = "kotlin.String", owner = "class:app/schema/Hidden")
    facts.decl("fun:app/LoaderFactory.create()", "fun", line = 7)

    val packages = facts.call(10, "fun:kotlin/collections/listOf(T)", listOf(facts.literal(10, "app.schema")))
    val config = facts.call(11, "ctor:com/expediagroup/graphql/generator/SchemaGeneratorConfig(kotlin/collections/List<kotlin/String>)", listOf(packages), params = listOf("supportedPackages"))
    val root = facts.call(12, "ctor:com/expediagroup/graphql/generator/TopLevelObject(kotlin/Any)", listOf(facts.node(12, "paramRef", type = "app.Queries")))
    val queries = facts.call(13, "fun:kotlin/collections/listOf(T)", listOf(root))
    facts.call(14, "fun:com/expediagroup/graphql/generator/toSchema(com/expediagroup/graphql/generator/SchemaGeneratorConfig)", listOf(config), listOf(queries), params = listOf("config", "queries"))
    val loader = facts.call(20, "fun:app/LoaderFactory.create()")
    facts.call(21, "fun:org/dataloader/DataLoaderRegistry.register(kotlin/String,org/dataloader/DataLoader<*,*>)", listOf(facts.literal(21, "Things")), listOf(loader))

    val resolvers = deriveResolvers(facts.index, facts.noDerived)

    assertEquals(
      listOf(
        Triple("dataLoader", "DataLoader", "Things"),
        Triple("field", "Thing", "owner"),
        Triple("query", "Query", "thing"),
      ),
      resolvers.map { Triple(it.kind, it.type, it.field) },
    )
    assertEquals("src/App.kt:21", resolvers.first().registeredAt)
    assertEquals("fun:app/LoaderFactory.create()", resolvers.first().decl)
  }

  @Test
  fun screensNavigationAndEntrypoints() {
    val facts = FactsBuilder()
    val override = listOf("override")
    facts.decl("class:app/HomeJourney", "class", line = 1)
    facts.supertype("class:app/HomeJourney", "$MAGELLAN/compose/ComposeJourney")
    facts.decl("fun:app/HomeJourney.Content()", "fun", line = 2, modifiers = override, owner = "class:app/HomeJourney")
    facts.decl("fun:app/HomeJourney.onCreate()", "fun", line = 3, modifiers = override, owner = "class:app/HomeJourney")
    facts.decl("class:app/BaseStep", "class", line = 5, modifiers = listOf("abstract"))
    facts.supertype("class:app/BaseStep", "$MAGELLAN/compose/ComposeStep")
    facts.decl("class:app/DetailStep", "class", line = 6)
    facts.supertype("class:app/DetailStep", "class:app/BaseStep")
    facts.decl("class:app/Banner", "class", line = 7)
    facts.supertype("class:app/Banner", "$MAGELLAN/compose/ComposeSection")
    facts.decl("class:app/Plain", "class", line = 8)
    facts.decl("fun:app/main()", "fun", line = 9)
    val created = facts.node(11, "objectCreation", type = "app.DetailStep", target = "class:app/DetailStep")
    val goTo = "fun:com/ryanmoelter/magellanx/compose/navigation/ComposeNavigator.goTo(com/ryanmoelter/magellanx/core/Navigable)"
    facts.call(11, goTo, listOf(created), caller = "fun:app/HomeJourney.onCreate()")
    facts.call(12, "fun:com/ryanmoelter/magellanx/compose/navigation/ComposeNavigator.goBack()", caller = "fun:app/HomeJourney.onCreate()")

    val index = facts.index
    val screens = deriveScreens(index)
    val navigations = deriveNavigations(index, facts.noDerived, screens)
    val entrypoints = deriveEntrypoints(index, emptyList(), emptyList(), screens)

    assertEquals(
      listOf("Banner" to "section", "BaseStep" to "step", "DetailStep" to "step", "HomeJourney" to "journey"),
      screens.map { it.cls.substringAfterLast('/') to it.kind },
    )
    val home = screens.last()
    assertEquals("fun:app/HomeJourney.Content()", home.content)
    assertEquals(listOf("onCreate"), home.lifecycle)
    assertEquals("abstract", screens[1].note)
    assertNull(screens[2].content)
    assertEquals(listOf("goTo" to "class:app/DetailStep", "goBack" to null), navigations.map { it.op to it.to })
    assertEquals(setOf("class:app/HomeJourney"), navigations.map { it.from }.toSet())
    assertEquals(
      listOf("composableContent" to "fun:app/HomeJourney.Content()", "lifecycleHook" to "fun:app/HomeJourney.onCreate()", "main" to "fun:app/main()"),
      entrypoints.map { it.kind to it.sym },
    )
  }
}
