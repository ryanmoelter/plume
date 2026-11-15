package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.rules.EntrypointFact
import com.ryanmoelter.altitude.rules.Rules
import com.ryanmoelter.altitude.trace.Site
import java.util.PriorityQueue

/**
 * A `cha` call with more candidates than this is left out of distances: it is generated dispatch
 * such as a JSON adapter, and every candidate would otherwise sit one hop from the caller.
 */
const val MEGAMORPHIC = 8

/** Boundary kinds that report on the program rather than move its data (rule B6). */
val TELEMETRY_KINDS = setOf("posthog", "sentry")

const val GRAPHQL_SERVES = "graphqlResolver"

/** Call edges that run a function value rather than call a declaration by name. */
val CALLBACK_VIAS = setOf("fnValue", "invoke", "assumedInvoke", "cell")

/** Call edges that name their callee: what a dependency is. */
val DIRECT_VIAS = setOf("static", "cha", "actual", "init", "delegateAccessor")

private val GATE_KINDS = setOf("fun", "ctor", "getter", "setter", "lambda")

/** The declaration-level call graph and what reaches what over it. */
class CallGraph(facts: Facts, derived: Derived, private val rules: Rules) {
  private val decls = facts.decls.associateBy { it.sym }
  private val constructors = facts.decls.filter { it.kind == "ctor" && it.owner != null }.groupBy({ it.owner!! }, { it.sym }).mapValues { it.value.sorted() }

  private val chaCount = derived.callEdges.filter { it.via == "cha" }.groupingBy { it.call }.eachCount()

  val edges: List<CallEdgeFact> =
    derived.callEdges.filter { !(it.via == "cha" && (chaCount[it.call] ?: 0) > MEGAMORPHIC) }

  val forward: Map<String, List<String>> =
    edges.groupBy({ it.caller }, { it.callee }).mapValues { (_, v) -> v.distinct().sorted() }

  val reverse: Map<String, List<String>> =
    edges.groupBy({ it.callee }, { it.caller }).mapValues { (_, v) -> v.distinct().sorted() }

  fun bfs(starts: Map<String, Int>, adjacency: Map<String, List<String>>, limit: Int = Int.MAX_VALUE): Map<String, Int> {
    val distance = HashMap(starts)
    val queue = ArrayDeque(starts.entries.sortedWith(compareBy({ it.value }, { it.key })).map { it.key })
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      val next = distance.getValue(current) + 1
      if (next > limit) continue
      for (n in adjacency[current].orEmpty()) {
        if (n in distance) continue
        distance[n] = next
        queue += n
      }
    }
    return distance
  }

  /** Per boundary kind, call hops from each declaration to a call of that kind; the caller is 1. */
  val boundaryDistance: Map<String, Map<String, Int>> =
    rules.boundaries.groupBy { it.kind }.toSortedMap().mapValues { (_, rows) ->
      bfs(rows.map { it.caller }.distinct().associateWith { 1 }, reverse)
    }

  /** The callables an entry point stands for. */
  fun callables(entry: EntrypointFact): List<String> =
    if (entry.attrs["serves"] == GRAPHQL_SERVES) rules.entrypoints.filter { it.kind == GRAPHQL_SERVES }.map { it.sym }.sorted()
    else listOf(entry.sym)

  val entries: List<EntrypointFact> = rules.entrypoints

  private val entryCallables: Set<String> = entries.flatMap(::callables).toSet()

  /**
   * Forward edges with the declarations that gate them. A callback (a lambda run through a function
   * value or a library) is only reached once the code that wrote it is: the folded call graph sends
   * every lambda passed to a shared component to every caller of that component.
   */
  private class Step(val callee: String, val via: String, val gates: List<String>?)

  private val steps: Map<String, List<Step>> =
    edges.groupBy { it.caller }.mapValues { (_, out) ->
      out.distinctBy { it.callee to it.via }.sortedWith(compareBy({ it.callee }, { it.via })).map { e ->
        val callee = decls[e.callee]
        Step(e.callee, e.via, if (e.via in CALLBACK_VIAS && callee?.kind == "lambda") gatesOf(callee.sym) else null)
      }
    }

  private fun gatesOf(lambda: String): List<String> {
    var current = decls[lambda]?.owner?.let { decls[it] }
    while (current != null) {
      if (current.kind in GATE_KINDS) return listOf(current.sym)
      if (current.kind in CLASS_KINDS) return listOf(current.sym) + constructors[current.sym].orEmpty()
      current = current.owner?.let { decls[it] }
    }
    return emptyList()
  }

  /**
   * Shortest call hops from [starts] over [steps], where a gated callback is entered only after one
   * of its gates. Another entry point's callable is entered only by a static call: framework
   * dispatch reaches every screen's `Content` and hooks, which says nothing about the caller.
   */
  fun reach(starts: Collection<String>): Map<String, Int> {
    val own = starts.toSet()
    val distance = HashMap<String, Int>()
    val queue = PriorityQueue<Pair<Int, String>>(compareBy<Pair<Int, String>> { it.first }.thenBy { it.second })
    val pending = HashMap<String, MutableList<Pair<String, Int>>>()
    for (s in starts.sorted()) queue += 0 to s
    while (queue.isNotEmpty()) {
      val (d, current) = queue.poll()
      if (current in distance) continue
      distance[current] = d
      pending.remove(current)?.forEach { (lambda, at) -> if (lambda !in distance) queue += maxOf(at, d) to lambda }
      for (step in steps[current].orEmpty()) {
        if (step.callee in distance) continue
        if (step.callee in entryCallables && step.callee !in own && step.via != "static") continue
        val gates = step.gates
        if (gates == null || gates.isEmpty() || gates.any { it in distance }) queue += d + 1 to step.callee
        else for (g in gates) pending.getOrPut(g) { ArrayList() } += step.callee to d + 1
      }
    }
    return distance
  }

  /** Per entry point kind, call hops from its callables; a callable is 0. */
  val entryDistance: Map<String, Map<String, Int>> =
    entries.groupBy { it.kind }.toSortedMap().mapValues { (_, rows) -> reach(rows.flatMap(::callables).distinct()) }

  /** The declarations each entry point reaches, by index into [entries]. */
  val reached: List<Set<String>> = entries.map { reach(callables(it)).keys }
}

/** A source position for evidence, `path:line`, ordered by position. */
fun siteOf(id: String, units: Units): Site? {
  Site.of(id)?.let { return it }
  val decl = units.decls[id] ?: units.decls[id.substringBeforeLast("#<").takeIf { "#<" in id } ?: ""] ?: return null
  val file = decl.file ?: return null
  val line = Units.span(decl.span)?.first ?: return null
  return Site(file, line, 0)
}

/** All value flows, extracted and derived, that move a value rather than describe a container. */
fun valueFlows(facts: Facts, derived: Derived): List<FlowFact> =
  (facts.flows + derived.flows).filter { it.kind !in setOf("memberOf", "partOf", "contentOf", "di") }
