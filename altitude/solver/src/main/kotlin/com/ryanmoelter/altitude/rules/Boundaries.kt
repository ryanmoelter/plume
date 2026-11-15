package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.SqlStatementFact

private const val APOLLO_CLIENT = "fun:com/apollographql/apollo/ApolloClient."
private val APOLLO_OPS = mapOf("query" to "read", "mutation" to "write", "subscription" to "read")
private val RETROFIT_METHODS = setOf("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")
private const val HTTP4K_CLIENT = "org/http4k/client"
private const val HTTP4K_THEN = "fun:org/http4k/core/then@org/http4k/core/Filter("
private const val HTTP4K_REQUEST = "class:org/http4k/core/Request"
private const val HTTP4K_METHOD = "enumEntry:org/http4k/core/Method."
private const val FUNCTION_INVOKE = "fun:kotlin/Function1.invoke("
private val VALUE_FUNCTIONS = setOf("equals", "hashCode", "toString", "copy")
private val POSTHOG_OPS = setOf("with", "setup", "capture", "screen", "identify", "reset", "flush", "close")
private val SENTRY_OPS = setOf("init", "configureScope", "captureException", "addBreadcrumb", "startTransaction")
private val SENTRY_SPAN_OPS = setOf("startChild", "finish")
private val SENTRY_SPANS = setOf("ISpan", "ITransaction")

/** B1–B6: the calls that leave the program, one row per call. */
fun deriveBoundaries(index: FactIndex, derived: Derived): List<BoundaryFact> = Boundaries(index, derived).derive()

private class Boundaries(private val index: FactIndex, derived: Derived) {
  private val statements: Map<Pair<String, String>, SqlStatementFact> =
    index.facts.sqlStatements.sortedWith(compareBy({ it.file }, { it.line })).associateBy { it.cls to it.label }

  private val derivedInto: Map<String, List<FlowFact>> = derived.flows.groupBy { it.to }

  private val callsByTarget: Map<String, List<CallFact>> = index.calls.groupBy { it.target }

  private val moduleOfFile: Map<String, String> = index.facts.files.associate { it.path to it.module }

  private val generatedFiles: Set<String> = index.facts.files.filter { it.generated }.map { it.path }.toSet()

  /** Modules that hold an SDK's own sources. A call into one is the boundary, so nothing inside is. */
  private val sdkModules = HashSet<String>()

  fun derive(): List<BoundaryFact> =
    index.calls
      .flatMap { call ->
        val id = CallableId.parse(call.target) ?: return@flatMap emptyList()
        sql(call, id) ?: apollo(call, id) ?: retrofit(call, id) ?: http(call, id) ?: revenueCat(call, id) ?: analytics(call, id) ?: emptyList()
      }
      .filter { moduleOfFile[it.file] !in sdkModules }
      .distinct()
      .sortedWith(compareBy({ it.file }, { it.line }, { it.call }, { it.op }))

  private fun row(
    call: CallFact,
    system: String,
    kind: String,
    op: String,
    target: String = call.target,
    access: String? = null,
    label: String? = null,
    sq: String? = null,
    operation: String? = null,
    via: String? = null,
    method: String? = null,
    path: String? = null,
    client: String? = null,
  ): List<BoundaryFact> {
    val file = index.fileOf(call.id) ?: return emptyList()
    val line = index.lineOf(call.id) ?: return emptyList()
    return listOf(
      BoundaryFact(system, kind, op, target, call.callerDecl, call.id, access, label, sq, operation, via, method, path, client, null, file, line)
    )
  }

  /** B1: a function of a generated queries class that a `.sq` statement labels. */
  private fun sql(call: CallFact, id: CallableId): List<BoundaryFact>? {
    if (id.kind != "fun" || index.fileOf(call.id) in generatedFiles) return null
    val statement = statements[(id.ownerClass ?: return null) to id.name] ?: return null
    val kind = if (statement.access == "write") "sqlWrite" else "sqlRead"
    return row(call, "sqldelight", kind, id.op, access = statement.access, label = id.name, sq = "${statement.file}:${statement.line}")
  }

  /** B2. A call that passes on a parameter of its own function moves to that function's callers. */
  private fun apollo(call: CallFact, id: CallableId): List<BoundaryFact>? {
    if (!call.target.startsWith(APOLLO_CLIENT)) return null
    val access = APOLLO_OPS[id.name] ?: return null
    val kind = "apollo" + id.name.replaceFirstChar(Char::uppercase)
    return index.argNodes(call, 0).flatMap { operations(call, it, null, 0) }.flatMap { (site, operation, helper) ->
      row(
        site,
        "apollo",
        kind,
        id.op,
        target = helper ?: call.target,
        access = access,
        operation = operation,
        via = helper?.let { CallableId.parse(it)?.name },
      )
    }
  }

  private fun operations(site: CallFact, node: String, helper: String?, depth: Int): List<Triple<CallFact, String, String?>> {
    val fact = index.nodes[node] ?: return emptyList()
    val type = dottedClassOf(fact.type) ?: return emptyList()
    val parameter = fact.target?.let(index.decls::get)?.takeIf { fact.kind == "paramRef" && it.kind == "param" }
    val owner = parameter?.owner
    val position = parameter?.index
    if (owner == null || position == null || !type.startsWith("com.apollographql.") || depth > 4) {
      return listOf(Triple(site, type, helper))
    }
    val callers = callsByTarget[owner].orEmpty()
    if (callers.isEmpty()) return listOf(Triple(site, type, helper))
    return callers.flatMap { caller -> index.argNodes(caller, position).flatMap { operations(caller, it, owner, depth + 1) } }
  }

  /** B3. */
  private fun retrofit(call: CallFact, id: CallableId): List<BoundaryFact>? {
    val annotation =
      index.annotationsOf(call.target).firstOrNull {
        it.annFq.startsWith("retrofit2/http/") && it.annFq.substringAfterLast('/') in RETROFIT_METHODS
      } ?: return null
    val value = annotation.values.firstOrNull { it.kind == "const" }?.value?.removeSurrounding("\"")
    return row(
      call,
      "retrofit",
      "retrofit",
      id.op,
      method = annotation.annFq.substringAfterLast('/'),
      path = value?.let { if (it.startsWith("/") || "://" in it) it else "/$it" },
    )
  }

  /** B4: the construction of an http4k client, and each invocation of a handler one flows to. */
  private fun http(call: CallFact, id: CallableId): List<BoundaryFact>? {
    if (id.pkg == HTTP4K_CLIENT && id.owners.size == 1 && (id.kind == "ctor" || id.name == "invoke")) {
      return row(call, "http", "httpOut", id.op, client = id.owners.single())
    }
    if (call.dispatch != "invokeFnValue" || !call.target.startsWith(FUNCTION_INVOKE)) return null
    val handler = call.receiver.firstNotNullOfOrNull { index.nodes[it]?.type?.takeIf { type -> type.startsWith("org.http4k.") } } ?: return null
    val client = search(call.receiver, 4000) { CallableId.parse(it.target)?.takeIf { made -> made.pkg == HTTP4K_CLIENT } } ?: return null
    val request = search(index.argNodes(call, 0), 200) { made -> made.takeIf { CallableId.parse(it.target)?.ownerClass?.startsWith(HTTP4K_REQUEST) == true && it.receiverType == null } }
    val method = request?.let { index.argNodes(it, 0) }?.firstNotNullOfOrNull { index.nodes[it]?.target?.takeIf { entry -> entry.startsWith(HTTP4K_METHOD) } }
    return row(
      call,
      "http",
      "httpOut",
      "${handler.substringBefore('<').removeSuffix("?").substringAfterLast('.')}.invoke",
      method = method?.removePrefix(HTTP4K_METHOD),
      path = request?.let { index.argNodes(it, 1) }?.firstNotNullOfOrNull(index::literalString),
      client = client.owners.firstOrNull(),
    )
  }

  /** Walks back from [start] along the flow of values to the first call [match] accepts. */
  private fun <T> search(start: List<String>, limit: Int, match: (CallFact) -> T?): T? {
    val seen = HashSet<String>()
    val queue = ArrayDeque(start)
    while (queue.isNotEmpty() && seen.size < limit) {
      val at = queue.removeFirst()
      if (!seen.add(at)) continue
      index.callsByResult[at]?.let { made ->
        match(made)?.let { return it }
        when {
          made.target.startsWith(HTTP4K_THEN) -> queue += index.argNodes(made, 0)
          made.receiverType == HTTP4K_REQUEST -> queue += made.receiver
          else -> {
            val callee = made.target.removeSuffix("#<get>")
            queue += listOf(callee, "$callee#<get>#<ret>", "$callee#<ret>")
          }
        }
      }
      index.nodes[at]?.target?.let { queue += it }
      index.flowsInto[at].orEmpty().forEach { queue += it.from }
      derivedInto[at].orEmpty().forEach { queue += it.from }
    }
    return null
  }

  /** B5: a call of a RevenueCat SDK function, but not of a builder or a property. */
  private fun revenueCat(call: CallFact, id: CallableId): List<BoundaryFact>? {
    if ("revenuecat" !in id.pkg.split('/')) return null
    if (id.kind == "prop" || id.owners.any { it.endsWith("Builder") } || id.name in VALUE_FUNCTIONS) return null
    // Building a client configures the SDK; any other constructor only makes a value to pass in.
    if (id.kind == "ctor" && !id.name.endsWith("Client")) return null
    val sdkModule = index.decls[call.target]?.file?.let(moduleOfFile::get)
    if (sdkModule != null) {
      if (sdkModule == moduleOfFile[index.fileOf(call.id)]) return null
      sdkModules += sdkModule
    }
    return row(call, "revenuecat", "revenuecat", id.op)
  }

  /** B6. */
  private fun analytics(call: CallFact, id: CallableId): List<BoundaryFact>? {
    if (id.kind == "prop") return null
    val owner = id.owners.lastOrNull { it != "Companion" }
    return when {
      id.pkg == "com/posthog" || id.pkg.startsWith("com/posthog/") -> {
        val config = owner?.endsWith("Config") == true && (id.kind == "ctor" || id.name == "invoke")
        if (config || (id.kind == "fun" && id.name in POSTHOG_OPS)) row(call, "posthog", "posthog", id.op) else null
      }
      id.pkg == "io/sentry" || id.pkg.startsWith("io/sentry/") -> {
        val sdk = id.name in SENTRY_OPS && (owner == "Sentry" || (id.name == "init" && owner?.startsWith("Sentry") == true))
        val span = id.name in SENTRY_SPAN_OPS && owner in SENTRY_SPANS
        if (id.kind == "fun" && (sdk || span)) row(call, "sentry", "sentry", id.op) else null
      }
      else -> null
    }
  }
}
