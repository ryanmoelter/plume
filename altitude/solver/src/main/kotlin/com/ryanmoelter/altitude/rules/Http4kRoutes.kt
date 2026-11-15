package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.Derived

private const val BIND = "fun:org/http4k/routing/bind@kotlin/String("
private const val ROUTES = "fun:org/http4k/routing/routes("
private const val TO = "fun:org/http4k/routing/PathMethod.to("
private const val THEN = "fun:org/http4k/core/then@org/http4k/core/Filter("
private const val FILTER_SAM = "fun:org/http4k/core/Filter("
private const val AS_SERVER = "fun:org/http4k/server/asServer@"
private const val METHOD_ENTRY = "enumEntry:org/http4k/core/Method."

/** What an expression of a route tree evaluates to. */
private sealed interface Shape {
  class Tree(val children: List<Shape>) : Shape

  /** `"/path" bind Method.X`, before `to` gives it a handler. */
  class PathMethod(val path: String?, val method: String?, val call: String) : Shape

  class Bound(val path: String?, val method: String?, val child: Shape, val call: String) : Shape

  class Filtered(val filters: List<String>, val inner: Shape) : Shape

  class Handler(val name: String, val at: String) : Shape

  class Unsure(val why: String, val inner: Shape) : Shape
}

/** E1–E6: walks every `routes` and `bind` expression, from each `asServer` receiver first. */
fun deriveRoutes(index: FactIndex, derived: Derived): List<RouteFact> = Http4kRoutes(index).derive()

private class Http4kRoutes(private val index: FactIndex) {
  private val visitedCalls = HashSet<String>()
  private val evaluating = HashSet<String>()
  private val rows = ArrayList<RouteFact>()

  fun derive(): List<RouteFact> {
    for (server in index.calls.filter { it.target.startsWith(AS_SERVER) }) {
      for (root in server.extReceiver + server.receiver) flatten(eval(root), Context(mounted = true))
    }
    val consumed = HashSet<String>()
    index.facts.args.forEach { consumed += it.node }
    index.calls.forEach { consumed += it.receiver; consumed += it.extReceiver }
    val routing = index.calls.filter { call -> listOf(ROUTES, TO, BIND).any { call.target.startsWith(it) } }
    for (call in routing) {
      if (call.id in visitedCalls || call.result == null || call.result in consumed) continue
      flatten(evalCall(call), Context(mounted = false))
    }
    return rows.distinct().sortedWith(compareBy({ it.file }, { it.line }, { it.path }, { it.method }, { it.handler }))
  }

  private fun eval(node: String): Shape {
    if (!evaluating.add(node)) return Shape.Handler(node, node)
    try {
      val fact = index.nodes[node] ?: return Shape.Handler(node, node)
      return when (fact.kind) {
        "lambdaExpr", "callableRef" -> Shape.Handler(fact.target ?: node, node)
        "propRef", "localRef", "paramRef" -> evalRef(node, fact.target ?: node)
        else -> index.callsByResult[node]?.let(::evalCall) ?: Shape.Handler(node, node)
      }
    } finally {
      evaluating -= node
    }
  }

  private fun evalRef(node: String, sym: String): Shape {
    if (sym !in index.decls) {
      // A library property is named by the source property it is read from, when there is one.
      val receivers = index.callsByResult[node]?.let { it.receiver + it.extReceiver }.orEmpty()
      val owner = receivers.firstNotNullOfOrNull { index.nodes[it]?.target?.takeIf { target -> target in index.decls } }
      return Shape.Handler(owner ?: sym, node)
    }
    val routed = valuesOf(sym).map(::eval).filter(::isRouting)
    return when (routed.size) {
      0 -> Shape.Handler(sym, node)
      1 -> routed.single()
      else -> Shape.Tree(routed.map { Shape.Unsure("conditional", it) })
    }
  }

  /** The expressions a property, local or function result takes its value from. */
  private fun valuesOf(sym: String): List<String> =
    listOf(sym, "$sym#<get>#<ret>", "$sym#<ret>")
      .flatMap { index.flowsInto[it].orEmpty() }
      .map { it.from }
      .filter { it in index.nodes }
      .distinct()

  private fun isRouting(shape: Shape): Boolean = shape !is Shape.Handler

  private fun evalCall(call: CallFact): Shape {
    val target = call.target
    return when {
      target.startsWith(BIND) -> {
        visitedCalls += call.id
        val path = call.extReceiver.singleOrNull()?.let(index::literalString)
        val operand = index.argNodes(call, 0)
        val method = operand.singleOrNull()?.let { index.nodes[it]?.target }?.takeIf { it.startsWith(METHOD_ENTRY) }
        if (method != null) Shape.PathMethod(path, method.removePrefix(METHOD_ENTRY), call.id)
        else Shape.Bound(path, null, alternatives(operand), call.id)
      }
      target.startsWith(TO) -> {
        visitedCalls += call.id
        val bound = call.receiver.singleOrNull()?.let(::eval)
        val handler = alternatives(index.argNodes(call, 0))
        if (bound is Shape.PathMethod) Shape.Bound(bound.path, bound.method, handler, bound.call) else handler
      }
      target.startsWith(ROUTES) -> {
        visitedCalls += call.id
        val children =
          index.args[call.id].orEmpty().flatMap { arg ->
            index.elements(arg.node).map { element ->
              val why = element.unsure ?: "spread".takeIf { arg.form == "spread" }
              eval(element.node).let { if (why == null) it else Shape.Unsure(why, it) }
            }
          }
        Shape.Tree(children)
      }
      target.startsWith(THEN) -> Shape.Filtered(call.extReceiver.flatMap(::filterNames), alternatives(index.argNodes(call, 0)))
      call.targetInSource || target in index.decls || target.removeSuffix("#<get>") in index.decls -> {
        val routed = valuesOf(target.removeSuffix("#<get>")).map(::eval).filter(::isRouting)
        when (routed.size) {
          0 -> Shape.Handler(target, call.id)
          1 -> routed.single()
          else -> Shape.Tree(routed.map { Shape.Unsure("conditional", it) })
        }
      }
      else -> Shape.Handler(target, call.id)
    }
  }

  /** Several nodes for one argument are the branches of a conditional. */
  private fun alternatives(nodes: List<String>): Shape =
    when (nodes.size) {
      0 -> Shape.Tree(emptyList())
      1 -> eval(nodes.single())
      else -> Shape.Tree(nodes.map { Shape.Unsure("conditional", eval(it)) })
    }

  /** E4: the names of the filters an expression of type `Filter` chains, outermost first. */
  private fun filterNames(node: String): List<String> {
    val fact = index.nodes[node] ?: return listOf(node)
    val call = index.callsByResult[node]
    return when {
      fact.kind in setOf("propRef", "localRef", "paramRef") -> listOf(named(fact.target ?: node))
      call == null -> listOf(node)
      call.target.startsWith(THEN) -> call.extReceiver.flatMap(::filterNames) + index.argNodes(call, 0).flatMap(::filterNames)
      call.target.startsWith(FILTER_SAM) ->
        index.argNodes(call, 0).map { index.nodes[it]?.takeIf { arg -> arg.kind == "lambdaExpr" }?.target ?: node }
      call.dispatch == "invokeFnValue" -> call.receiver.map { named(index.nodes[it]?.target ?: it) }
      else -> listOf(named(call.target))
    }
  }

  /** A source declaration keeps its ID; a library one reads as `a.b.Owner.name`. */
  private fun named(sym: String): String =
    if (sym in index.decls) sym else CallableId.parse(sym)?.dottedName ?: sym

  private class Context(
    val mounted: Boolean,
    val prefix: String = "",
    val method: String? = null,
    val filters: List<String> = emptyList(),
    val bind: String? = null,
    val unsure: String? = null,
    val dynamicPath: Boolean = false,
  )

  private fun flatten(shape: Shape, context: Context) {
    when (shape) {
      is Shape.Tree -> shape.children.forEach { flatten(it, context) }
      is Shape.PathMethod -> Unit
      is Shape.Bound ->
        flatten(
          shape.child,
          Context(
            mounted = context.mounted,
            prefix = context.prefix + (shape.path ?: "/{dynamic}"),
            method = shape.method ?: context.method,
            filters = context.filters,
            bind = shape.call,
            unsure = context.unsure,
            dynamicPath = context.dynamicPath || shape.path == null,
          ),
        )
      is Shape.Filtered ->
        flatten(
          shape.inner,
          Context(context.mounted, context.prefix, context.method, context.filters + shape.filters, context.bind, context.unsure, context.dynamicPath),
        )
      is Shape.Unsure ->
        flatten(
          shape.inner,
          Context(context.mounted, context.prefix, context.method, context.filters, context.bind, context.unsure ?: shape.why, context.dynamicPath),
        )
      is Shape.Handler -> {
        val at = context.bind ?: shape.at
        val decl = index.decls[at]
        val file = index.fileOf(at) ?: decl?.file ?: return
        val line = index.lineOf(at) ?: index.line(decl) ?: return
        val why = context.unsure ?: "path built at run time".takeIf { context.dynamicPath }
        val notes = listOfNotNull(why, "no server root reaches this route tree".takeIf { !context.mounted })
        rows +=
          RouteFact(
            method = context.method ?: "ANY",
            path = normalize(context.prefix),
            handler = shape.name,
            filters = context.filters,
            mounted = context.mounted,
            confidence = "unsure".takeIf { why != null },
            note = notes.joinToString("; ").ifEmpty { null },
            file = file,
            line = line,
          )
      }
    }
  }

  /** E2: one `/` between segments, and no trailing `/` unless the path is `/`. */
  private fun normalize(path: String): String {
    val joined = path.replace(Regex("/+"), "/").removeSuffix("/")
    return if (joined.isEmpty()) "/" else if (joined.startsWith("/")) joined else "/$joined"
  }
}
