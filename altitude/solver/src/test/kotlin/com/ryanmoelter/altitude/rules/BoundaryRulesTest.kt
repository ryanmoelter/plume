package com.ryanmoelter.altitude.rules

import kotlin.test.Test
import kotlin.test.assertEquals

class BoundaryRulesTest {
  @Test
  fun aLabelledQueriesFunctionIsADatabaseCallOutsideGeneratedCode() {
    val facts = FactsBuilder()
    val generated = "gen/sqldelight/ThingQueries.kt"
    facts.generatedFile(generated)
    facts.statement("class:app/db/ThingQueries", "findAll", "read", line = 4)
    facts.statement("class:app/db/ThingQueries", "insert", "write", line = 9)
    facts.call(1, "fun:app/db/ThingQueries.findAll()")
    facts.call(2, "fun:app/db/ThingQueries.insert(kotlin/String)")
    facts.call(3, "fun:app/db/ThingQueries.transaction(kotlin/Function0)")
    facts.call(4, "fun:app/sync/SyncQueries.findAll()")
    facts.call(5, "fun:app/db/ThingQueries.findAll()", file = generated)

    val rows = deriveBoundaries(facts.index, facts.noDerived)

    assertEquals(listOf("sqlRead" to "findAll", "sqlWrite" to "insert"), rows.map { it.kind to it.label })
    assertEquals("src/sqldelight/App.sq:4", rows.first().sq)
    assertEquals(listOf(1, 2), rows.map { it.line })
  }

  /** A helper that forwards its parameter to `ApolloClient.mutation` yields a row per helper call. */
  @Test
  fun apolloOperationsNameTheConcreteArgument() {
    val facts = FactsBuilder()
    val helper = "fun:app/send@com/apollographql/apollo/ApolloClient(com/apollographql/apollo/api/Mutation<D>)"
    facts.decl(helper, "fun")
    facts.decl("$helper#m", "param", owner = helper, index = 0)
    facts.call(1, "fun:com/apollographql/apollo/ApolloClient.query(com/apollographql/apollo/api/Query<D>)", listOf(facts.node(1, "objectCreation", type = "app.api.FindQuery")))
    val forwarded = facts.node(2, "paramRef", type = "com.apollographql.apollo.api.Mutation<D>", target = "$helper#m", scope = helper)
    facts.call(2, "fun:com/apollographql/apollo/ApolloClient.mutation(com/apollographql/apollo/api/Mutation<D>)", listOf(forwarded), caller = helper)
    facts.call(3, helper, listOf(facts.node(3, "objectCreation", type = "app.api.SaveMutation")))

    val rows = deriveBoundaries(facts.index, facts.noDerived)

    assertEquals(
      listOf(Triple(1, "app.api.FindQuery", null), Triple(3, "app.api.SaveMutation", "send")),
      rows.map { Triple(it.line, it.operation, it.via) },
    )
    assertEquals(listOf("read", "write"), rows.map { it.access })
    assertEquals(helper, rows.last().target)
  }

  @Test
  fun retrofitAndSdkCalls() {
    val facts = FactsBuilder()
    facts.annotation("fun:app/RestApi.logIn(app/Login)", "retrofit2/http/POST", "auth/login")
    facts.call(1, "fun:app/RestApi.logIn(app/Login)", dispatch = "virtual")
    facts.call(2, "fun:app/FakeRestApi.logIn(app/Login)")
    facts.call(3, "fun:com/posthog/PostHog.Companion.capture(kotlin/String)")
    facts.call(4, "prop:com/posthog/PostHog.Companion.distinctId#<get>")
    facts.call(5, "fun:io/sentry/Sentry.captureException(kotlin/Throwable)")
    facts.call(6, "fun:io/sentry/SentryBaseEvent.addBreadcrumb(io/sentry/Breadcrumb)")
    facts.call(7, "fun:com/revenuecat/purchases/awaitLogIn@com/revenuecat/purchases/Purchases(kotlin/String)")
    facts.call(8, "fun:com/revenuecat/purchases/PurchasesConfiguration.Builder.build()")

    val rows = deriveBoundaries(facts.index, facts.noDerived)

    assertEquals(
      listOf("retrofit" to "logIn", "posthog" to "PostHog.Companion.capture", "sentry" to "Sentry.captureException", "revenuecat" to "awaitLogIn"),
      rows.map { it.system to it.op },
    )
    assertEquals("POST" to "/auth/login", rows.first().method to rows.first().path)
  }

  /** `val handler = filter.then(OkHttp()); handler(Request(GET, "/rates"))`. */
  @Test
  fun anInvokedClientHandlerIsAnOutboundRequest() {
    val facts = FactsBuilder()
    facts.decl("prop:app/Api.handler", "prop")
    val client = facts.call(1, "fun:org/http4k/client/OkHttp.invoke(okhttp3/OkHttpClient)")
    val filtered = facts.call(2, "fun:org/http4k/core/then@org/http4k/core/Filter(kotlin/Function1<org/http4k/core/Request,org/http4k/core/Response>)", listOf(client))
    facts.flow(filtered, "prop:app/Api.handler")
    val method = facts.node(3, "propRef", target = "enumEntry:org/http4k/core/Method.GET")
    val request = facts.call(3, "fun:org/http4k/core/Request.Companion.invoke(org/http4k/core/Method,kotlin/String)", listOf(method), listOf(facts.literal(3, "/rates")))
    val handler = facts.node(4, "propRef", type = "org.http4k.core.HttpHandler", target = "prop:app/Api.handler")
    facts.call(4, "fun:kotlin/Function1.invoke(P1)", listOf(request), receiver = handler, dispatch = "invokeFnValue")
    val other = facts.node(5, "paramRef", type = "org.http4k.core.HttpHandler", target = "fun:app/serve()#next")
    facts.call(5, "fun:kotlin/Function1.invoke(P1)", listOf(request), receiver = other, dispatch = "invokeFnValue")

    val rows = deriveBoundaries(facts.index, facts.noDerived)

    assertEquals(listOf("client", "request"), rows.map { it.op })
    assertEquals(listOf("OkHttp", "OkHttp"), rows.map { it.client })
    assertEquals("GET" to "/rates", rows.last().method to rows.last().path)
    assertEquals(4, rows.last().line)
  }
}
