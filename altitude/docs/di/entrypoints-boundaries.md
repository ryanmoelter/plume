# Entry points and boundaries

This spec says how Altitude finds where control enters a program (entry points) and where it leaves for another system (boundaries). Each rule names its identifying facts and its output row. Every row carries a repo-relative `file` and a `line`. `line` is the first line of the decl span for a declaration, and the start line of the call ID for a call.

Libraries named here, as the targets pin them: http4k (backend), graphql-kotlin with its http4k glue (backend), Magellan X (`com.ryanmoelter.magellanx`, app), Apollo Kotlin 4 (app), SQLDelight 2 (both), Retrofit (app), RevenueCat (both), PostHog and Sentry (both).

## http4k routes

**E1. Route tree.** A call to the infix `bind` on a `String` (`org.http4k.routing.bind@kotlin/String`) makes a path binding. Its right operand is one of:

- a `Method`, giving `PathMethod`, followed by `to <HttpHandler>`. That is a leaf.
- an `HttpHandler` or `RoutingHttpHandler`. That is a mount.

A call to `routes(...)` (`org.http4k.routing.routes`) groups its vararg arguments. The analyzer walks arguments through `arg` facts to build the tree.

**E2. Path.** A leaf's path is the concatenation of every enclosing `bind` path, outermost first. Drop a trailing `/` unless the whole path is `/`. A mount whose operand is a call to a function returning `RoutingHttpHandler` (`inviteRoutes.routes()`) continues into that function's `routes(...)` call. Follow the `callEdge` to it.

**E3. Handler.** The leaf's handler is the `to` operand. When it is a lambda, the handler is the lambda ID. When it is `filter.then(handler)`, the filters join the route's `filters` list (E4) and the handler is the innermost operand.

Output row `route`: `method` (`GET`, `POST`, or `ANY` for a mount with no method), `path`, `handler` (decl or lambda ID), `filters` (outermost first), `mounted` (`false` when no server root reaches the route tree), `file`, `line` of the `bind` call for the leaf.

**E4. Filters.** A call to `Filter.then(x)` (`org.http4k.core.then@org/http4k/core/Filter`) puts its receiver in front of x. The global chain is every filter on the path from the server root to the route tree. A route's `filters` holds the global chain, then the filters on its own path. A filter is named by its source: a property ID (`prop:...InitSentryFilter`-typed accessor), an `object` expression's node ID, or a library call such as `org.http4k.filter.ServerFilters.CatchAll`.

**E5. Server root.** A call to `asServer` (`org.http4k.server.asServer@org/http4k/core/HttpHandler`) names the root handler as its receiver. A route is `mounted` when this root reaches it.

**E6. Conditional routes.** A route added inside an `if`, or from a `listOfNotNull` or a spread, gets `confidence: "unsure"` and a note naming the condition.

```kotlin
"/auth" bind routes(
  "/login" bind routes("/" bind Method.POST to { req -> login(req) }),
)
```

## graphql-kotlin

**E7. Schema roots.** A call to `toSchema` (`com.expediagroup.graphql.generator.toSchema`) takes `config`, `queries`, `mutations` and `subscriptions`. Each list holds `TopLevelObject(x)` calls. The class of x's static type is a root class of that kind. `config` carries `supportedPackages`, a list of string literals.

**E8. Operations.** Each public function of a root class is one operation, named after the function. Skip functions annotated `GraphQLIgnore`, and functions inherited from `Any`. Output row `resolver`: `kind` (`query`, `mutation` or `subscription`), `type` (`Query`, `Mutation`, `Subscription`), `field` (the function name), `decl` (function ID), `file`, `line`.

**E9. Field resolvers.** Start from the return types of every operation. Collect output types: unwrap `List`, `Set`, nullable, `DataFetcherResult` and `CompletableFuture`. Keep a type only when its package starts with one of `supportedPackages`. For each kept class, its interface subtypes from `supertype` facts in those packages also count, because graphql-kotlin exposes a sealed or abstract interface's implementations. Recurse into the types of public properties and the return types of public functions.

Every public member function (not a property) of a kept output type is a field resolver. Kind `field`, `type` = simple class name. Skip `GraphQLIgnore` members. Skip input types: a type reached only through operation parameters is an input, and input types have no resolvers. A class that no root reaches is not in the schema, so its functions are not resolvers.

**E10. DataLoaders.** A loader is registered in one of two ways:

- a call to `org.dataloader.DataLoaderRegistry.register(name, loader)`. The name is the first argument, a string constant or a `const val`. The loader is the second argument. When it is a call such as `factory.createDataLoader(ctx)`, `decl` is that function.
- a class that implements `com.expediagroup.graphql.dataloader.KotlinDataLoader`. Its `dataLoaderName` is the name and `decl` is the class.

A field resolver that calls `DataFetchingEnvironment.getValueFromDataLoader(name, key)` uses the loader of that name. Output row `resolver` with `kind: "dataLoader"`, `field` = the loader name, `decl`, and `registeredAt` (the `register` call's file and line) for the first form. heypenny-backend uses only the first form.

## Magellan X screens

**E11. Screen classes.** A class is a screen when its supertype closure (from `supertype` facts) holds one of these, checked in this order:

1. `com.ryanmoelter.magellanx.compose.ComposeJourney`: `kind: "journey"`
2. `ComposeStep`, `SimpleComposeStep` or `com.ryanmoelter.magellanx.core.Navigable`: `kind: "step"`
3. `ComposeSection` (or `com.ryanmoelter.magellanx.core.Displayable` without Navigable): `kind: "section"`

A wrapper such as `WrapperStep` (Navigable plus a section) is a step. An abstract class is a screen with `note: "abstract"`.

**E12. Content.** The class's override of `Content()` (a `@Composable` function) is its UI entry point. Output field `content` = that function's ID, or absent when it inherits one.

**E13. Lifecycle hooks.** An override of `onCreate`, `onShow`, `onResume`, `onPause`, `onHide`, `onDestroy` or `onBackPressed` in the class is a lifecycle entry point. Output field `lifecycle` = the sorted list of hook names.

**E14. Navigation.** A call to `ComposeNavigator.goTo`, `goBack`, `navigate`, `replace` or `resetWithRoot` is a navigation edge. Its argument is the destination: the class of an `objectCreation` node, or the type of a property or factory call. Output row `navigation` (not part of the screens oracle yet): `from` (enclosing screen class), `call`, `to`.

Output row `screen`: `class`, `kind`, `content`, `lifecycle`, `file`, `line`.

## Boundaries

A boundary is a call that leaves the program. Output row `boundary`: `system`, `op`, `target` (the library callee ID), `caller` (enclosing decl ID), `file`, `line`, plus the fields each rule names.

**B1. SQLDelight.** A call whose target is a function of a class named `*Queries` that is declared in a generated file under `gen/<project>/generated/sqldelight/` is a database call. A hand-written class named `SyncQueries` does not count. Fields:

- `label`: the function name, which is the label of a statement in a `.sq` file.
- `sq`: the `.sq` file and line where `label:` starts. Find it by scanning the module's `src/*/sqldelight` tree. SQLDelight names the queries class after the `.sq` file, so `ExpenseQueries` maps to `Expense.sq`.
- `access`: `read` when the statement starts with `SELECT` or `WITH ... SELECT`; `write` for `INSERT`, `UPDATE`, `DELETE`, `REPLACE` or `UPSERT`. A grouped statement (`label { ... }`) is `write` when any inner statement writes.

**B2. Apollo.** A call to `ApolloClient.query(q)`, `ApolloClient.mutation(m)` or `ApolloClient.subscription(s)` is a GraphQL request. Field `operation` = the class of the argument's static type, a generated `*Query`, `*Mutation` or `*Subscription`. When the call sits in a generic helper (`fun <D : Mutation.Data> ApolloClient.failablyMutate(m: Mutation<D>)`), the row goes to each call of the helper instead, with the concrete argument type. `access`: `read` for a query, `write` for a mutation.

**B3. Retrofit.** An interface whose functions carry `retrofit2.http.GET`, `POST`, `PUT`, `DELETE` or `PATCH` is a Retrofit API. A call to one of its functions is a boundary with `method` and `path` from the annotation. A fake implementation of the interface in main sources is not a boundary; skip calls dispatched only to it.

**B4. Outbound http4k.** A call that invokes an `HttpHandler` built from a client constructor (`org.http4k.client.OkHttp`, `JavaHttpClient`, `ApacheClient`) is an outbound request. Trace the handler value through `flow` to its constructor. Fields: `client` (the constructor), and `method` and `path` when the argument is a `Request(Method.X, "...")` with a literal or template path.

**B5. RevenueCat.** Calls into `com.revenuecat.purchases` (app) and into the generated `DeveloperAPIClient` of `:revenuecat-api` (backend) are boundaries with `system: "revenuecat"`.

**B6. Analytics and error reporting.** Calls into `com.posthog` are `system: "posthog"`. Calls into `io.sentry` are `system: "sentry"`. Record only calls that send, start or configure the SDK:

- PostHog: `with`, `setup`, the config constructor or `invoke`, `capture`, `screen`, `identify`, `reset`, `flush`, `close`.
- Sentry: `init`, `configureScope`, `captureException`, `addBreadcrumb` on `Sentry`, `startTransaction`, and `ISpan.startChild` and `finish`.

Skip reads and object setup: `distinctId`, `Breadcrumb.setData`, `SentryBaseEvent.addBreadcrumb`, `SentryOptions` setters. For RevenueCat (B5), skip the `Builder` calls of `PurchasesConfiguration` and `PaywallOptions`, and keep `configure`, the `await*` calls and paywall composables.

## What source cannot derive

- A route path built at run time, from a variable or a config value. Emit `confidence: "unsure"`.
- A Magellan destination chosen at run time from a list or a `when`. List each candidate.
- graphql-kotlin hooks (`SchemaGeneratorHooks`) can add or rename types. Read the hooks class if `config` sets one.
- Apollo's normalized cache can answer a query without a network call. The row still marks a boundary.
