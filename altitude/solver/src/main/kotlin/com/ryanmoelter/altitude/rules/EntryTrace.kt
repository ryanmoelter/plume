package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.Tracer

/**
 * `trace --from-entrypoint <sel> --to-boundary <sel>`: the call paths from the entry points a selector
 * names to the boundaries another names, each traced by [Tracer.trace] from the nearest entry point.
 */
private const val MAX_TRACED = 5

class EntryTrace(private val program: Program, private val rules: Rules, private val tracer: Tracer) {
  /**
   * An entry selector is a route path (`/graphql`), `METHOD /path`, a resolver field or `Type.field`,
   * a screen class, or the entry point's callable as a [Program.select] selector.
   */
  fun entrypoints(selector: String): List<EntrypointFact> {
    val selected = program.select(selector).decls.toSet()
    return rules.entrypoints.filter { entry ->
      val a = entry.attrs
      entry.sym == selector ||
        entry.sym in selected ||
        a["path"] == selector ||
        "${a["method"]} ${a["path"]}" == selector ||
        a["field"] == selector ||
        "${a["type"]}.${a["field"]}" == selector ||
        a["screen"]?.let { it == selector || FactIndex.dotted(it).let { d -> d == selector || d.endsWith(".$selector") } } == true
    }
  }

  /** A boundary selector is a label, an `op`, a `kind`, `system:kind`, or the target as a selector. */
  fun boundaries(selector: String): List<BoundaryFact> {
    val selected = program.select(selector, includeLibrary = true).let { it.decls + it.library }.toSet()
    return rules.boundaries.filter { b ->
      b.label == selector || b.op == selector || b.kind == selector || "${b.system}:${b.kind}" == selector ||
        b.target == selector || b.target in selected
    }
  }

  /** graphql-java calls resolvers by reflection, so a route that serves them stands for all of them. */
  private fun callables(entry: EntrypointFact): List<String> =
    if (entry.attrs["serves"] == "graphqlResolver") {
      rules.entrypoints.filter { it.kind == "graphqlResolver" }.map { it.sym }.sorted()
    } else {
      listOf(entry.sym)
    }

  private val callees: Map<String, List<String>> =
    program.derived.callEdges.groupBy({ it.caller }, { it.callee }).mapValues { (_, v) -> v.distinct().sorted() }

  /** Call-graph hops from [from] to each declaration it reaches. */
  private fun distances(from: String): Map<String, Int> {
    val distance = linkedMapOf(from to 0)
    val queue = ArrayDeque(listOf(from))
    while (queue.isNotEmpty()) {
      val next = queue.removeFirst()
      for (callee in callees[next].orEmpty()) {
        if (callee in distance) continue
        distance[callee] = distance.getValue(next) + 1
        queue += callee
      }
    }
    return distance
  }

  fun trace(from: String, to: String): String = buildString {
    val entries = entrypoints(from)
    val targets = boundaries(to)
    if (entries.isEmpty()) {
      appendLine("No entry point matches $from.")
      return@buildString
    }
    if (targets.isEmpty()) {
      appendLine("No boundary matches $to.")
      return@buildString
    }
    appendLine("Entry points matching $from: ${entries.size}")
    for (entry in entries) appendLine("  ${describe(entry)}")
    appendLine("Boundaries matching $to: ${targets.size}, ${targets.map { it.target }.distinct().size} target(s)")
    appendLine()

    class Reach(val callable: String, val target: String, val hops: Int)
    val reaches = ArrayList<Reach>()
    for (callable in entries.flatMap(::callables).distinct()) {
      val distance = distances(callable)
      for (b in targets) distance[b.caller]?.let { reaches += Reach(callable, b.target, it + 1) }
    }
    if (reaches.isEmpty()) {
      appendLine("No matching entry point reaches a matching boundary over call edges.")
      return@buildString
    }
    val byTarget = reaches.groupBy { it.target }.toSortedMap()
    for ((target, all) in byTarget) {
      val starts = all.sortedWith(compareBy({ it.hops }, { it.callable })).map { it.callable }.distinct()
      val traced = starts.take(MAX_TRACED)
      appendLine("== ${program.display(target)}: reached from ${starts.size} entry callable(s), nearest first ==")
      for (callable in starts.drop(MAX_TRACED)) appendLine("  not traced: ${program.display(callable)}")
      for (callable in traced) {
        appendLine()
        append(tracer.trace(callable, target))
      }
      appendLine()
    }
  }

  private fun describe(entry: EntrypointFact): String {
    val a = entry.attrs
    val what =
      when (entry.kind) {
        "httpRoute" -> "${a["method"]} ${a["path"]}" + (if (a["mounted"] == "false") " (not mounted)" else "")
        "graphqlResolver" -> "${a["type"]}.${a["field"]}"
        else -> a["screen"]?.let(FactIndex::dotted) ?: entry.kind
      }
    val serves = if (a["serves"] == "graphqlResolver") ", serving every GraphQL resolver" else ""
    return "${entry.kind} $what → ${program.display(entry.sym)}$serves"
  }
}
