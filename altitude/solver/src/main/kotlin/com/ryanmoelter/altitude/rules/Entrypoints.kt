package com.ryanmoelter.altitude.rules

private const val GRAPHQL_HANDLER = "fun:org/http4k/routing/graphQL("

/**
 * The route, resolver and screen rows as one relation, plus every top-level `main`. [EntrypointFact.sym]
 * is the callable that runs: a handler lambda or function, a resolver function, a `Content` function
 * or a lifecycle hook. A route served by a library handler names that library callable.
 */
fun deriveEntrypoints(
  index: FactIndex,
  routes: List<RouteFact>,
  resolvers: List<ResolverFact>,
  screens: List<ScreenFact>,
): List<EntrypointFact> {
  val rows = ArrayList<EntrypointFact>()
  for (route in routes) {
    val attrs =
      sortedMapOf(
        "method" to route.method,
        "path" to route.path,
        "filters" to route.filters.joinToString(","),
        "mounted" to route.mounted.toString(),
      )
    route.confidence?.let { attrs["confidence"] = it }
    if (route.handler !in index.decls) attrs["handler"] = "library"
    // graphql-java calls the resolvers by reflection, so no call edge leaves this handler.
    if (route.handler.startsWith(GRAPHQL_HANDLER)) attrs["serves"] = "graphqlResolver"
    rows += EntrypointFact("httpRoute", route.handler, attrs, route.file, route.line)
  }
  for (resolver in resolvers) {
    val attrs = sortedMapOf("operationType" to resolver.kind, "type" to resolver.type, "field" to resolver.field)
    resolver.registeredAt?.let { attrs["registeredAt"] = it }
    rows += EntrypointFact("graphqlResolver", resolver.decl, attrs, resolver.file, resolver.line)
  }
  for (screen in screens) {
    val attrs = mapOf("screen" to screen.cls, "screenKind" to screen.kind)
    screen.content?.let { content ->
      rows += EntrypointFact("composableContent", content, attrs, screen.file, index.line(index.decls[content]))
    }
    for (hook in index.memberFunctions(screen.cls).filter { it.name in screen.lifecycle && index.has(it, "override") }) {
      rows += EntrypointFact("lifecycleHook", hook.sym, attrs + ("hook" to hook.name), hook.file, index.line(hook))
    }
  }
  for (main in index.decls.values) {
    if (main.kind != "fun" || main.name != "main" || main.owner?.startsWith("file:") != true) continue
    rows += EntrypointFact("main", main.sym, emptyMap(), main.file, index.line(main))
  }
  return rows.distinct().sortedWith(compareBy({ it.kind }, { it.sym }, { it.attrs.toString() }))
}
