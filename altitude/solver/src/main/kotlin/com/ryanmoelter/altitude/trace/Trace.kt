package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.FlowFact

class TraceOptions(
  val maxDepth: Int = 30,
  /** Paths printed after the shortest. */
  val alternates: Int = 3,
  /** Paths enumerated before the count is reported as a lower bound. */
  val pathLimit: Int = 1000,
  /** Lines `--forward` prints. */
  val forwardLimit: Int = 200,
  val searchBudget: Int = 2_000_000,
)

private const val INDENT = "      "

/** Text reports over a [Program]. Every report says what it left out. */
class Tracer(private val program: Program, private val options: TraceOptions = TraceOptions()) {

  fun trace(from: String, to: String): String = buildString {
    val start = program.select(from)
    val goal = program.select(to, includeLibrary = true)
    if (!requireUnique(start, "--from") || !requireUnique(goal, "--to")) return@buildString
    val source = start.decls.single()
    val libraryGoal = goal.library.singleOrNull()
    val goalName = goal.decls.singleOrNull()?.let(program::display) ?: program.display(libraryGoal!!)
    appendLine("Trace from ${program.display(source)}")
    appendLine("        to $goalName")
    if (libraryGoal == null && program.constructorsOf(goal.decls.single()).isNotEmpty()) {
      appendLine("        (a class: the paths end at its constructors)")
    }
    appendLine()

    val ends: Map<String, List<CallFact>> =
      if (libraryGoal != null) {
        program.boundaryCalls
          .mapValues { (_, calls) -> calls.filter { it.target == libraryGoal } }
          .filterValues { it.isNotEmpty() }
      } else {
        program.constructorsOf(goal.decls.single()).ifEmpty { goal.decls }.associateWith { emptyList() }
      }
    val distance = distancesTo(ends.keys)
    if (source !in distance || distance.getValue(source) > options.maxDepth) {
      noPath(source, goalName, distance)
      return@buildString
    }
    val search = PathSearch(program, distance, ends.keys, options)
    val paths = search.run(source)
    val total =
      if (search.complete) "${paths.size}" else "at least ${paths.size}"
    appendLine(
      "Paths: $total within ${options.maxDepth} hops. A path is a sequence of declarations; " +
        "where two declarations are joined by several call sites, the first is shown."
    )
    if (!search.complete) appendLine("The search stopped early: ${search.stopReason}.")
    val shown = paths.take(1 + options.alternates)
    if (shown.size < paths.size) {
      appendLine(
        "Showing the shortest and ${shown.size - 1} alternates; " +
          "${paths.size - shown.size} more are not printed."
      )
    }
    shown.forEachIndexed { index, path ->
      appendLine()
      val label = if (index == 0) "Shortest path" else "Alternate $index"
      appendLine("== $label (${path.size + (if (libraryGoal != null) 1 else 0)} hops) ==")
      for (hop in path) hop(hop)
      if (libraryGoal != null) {
        val last = path.lastOrNull()?.callee ?: source
        val calls = ends.getValue(last)
        boundary(calls.first(), calls.size - 1)
      }
    }
  }

  fun forward(from: String): String = buildString {
    val start = program.select(from)
    if (!requireUnique(start, "--from")) return@buildString
    val source = start.decls.single()
    val depth = LinkedHashMap<String, Int>()
    val queue = ArrayDeque(listOf(source))
    depth[source] = 0
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      val next = depth.getValue(current) + 1
      if (next > options.maxDepth) continue
      for (hop in program.hops[current].orEmpty()) {
        if (hop.callee !in depth) {
          depth[hop.callee] = next
          queue += hop.callee
        }
      }
    }
    val boundary =
      depth.entries
        .flatMap { (decl, d) -> program.boundaryCalls[decl].orEmpty().map { d to it } }
        .sortedWith(compareBy({ it.first }, { Site.of(it.second.id) }, { it.second.id }))
    val deadInvokes =
      program.facts.calls.count {
        it.callerDecl in depth && it.dispatch == "invokeFnValue" && program.fanOut[it.id] == 0
      }
    appendLine("Forward from ${program.display(source)}")
    appendLine(
      "Reaches ${depth.size} declarations within ${options.maxDepth} hops, which make " +
        "${boundary.size} calls into code outside the sources."
    )
    appendLine(
      "$deadInvokes function-value invokes in those declarations have no known target; " +
        "what they run is missing below."
    )
    if (boundary.size > options.forwardLimit) {
      appendLine(
        "Showing the ${options.forwardLimit} nearest; ${boundary.size - options.forwardLimit} " +
          "are not printed."
      )
    }
    appendLine()
    for ((d, call) in boundary.take(options.forwardLimit)) {
      appendLine(
        "${Site.of(call.id)}  ${program.display(call.callerDecl)}  --call [library]-->  " +
          "${program.display(call.target)}  (depth $d)"
      )
    }
  }

  fun show(file: String): String = buildString {
    val decls = program.facts.decls.filter { it.file == file }
    if (decls.isEmpty() && program.facts.files.none { it.path == file }) {
      appendLine("No file $file in the facts. Paths are relative to the repository root.")
      return@buildString
    }
    appendLine("== declarations of $file ==")
    for (decl in decls.sortedWith(compareBy({ Site.of("$file:${it.span}") }, { it.sym }))) {
      val details =
        listOfNotNull(decl.type, decl.modifiers.joinToString(" ").ifEmpty { null }).joinToString("; ")
      appendLine("$file:${decl.span?.substringBefore(':')}  ${decl.kind}  ${program.display(decl.sym)}  [$details]")
      appendLine("$INDENT${decl.sym}")
    }
    appendLine()
    appendLine("== calls of $file ==")
    val edges = program.derived.callEdges.groupBy { it.call }
    val calls = program.facts.calls.filter { Site.of(it.id)?.path == file }
    for (call in calls.sortedWith(compareBy({ Site.of(it.id) }, { it.id }))) {
      appendLine(
        "${Site.of(call.id)}  ${program.display(call.callerDecl)}  --${call.dispatch}-->  " +
          program.display(call.target)
      )
      for (edge in edges[call.id].orEmpty().sortedBy { it.callee }) {
        appendLine("$INDENT--${describe(edge.via, call)}-->  ${program.display(edge.callee)}")
      }
    }
    appendLine()
    appendLine("== flow edges of $file ==")
    val flows =
      (program.facts.flows + program.derived.flows).filter { Site.of(it.at)?.path == file }
    for (flow in flows.sortedWith(compareBy({ Site.of(it.at) }, { it.from }, { it.to }))) flow(flow, "")
  }

  private fun StringBuilder.requireUnique(selection: Selection, option: String): Boolean {
    if (selection.isUnique) return true
    val all = selection.decls + selection.library
    if (all.isEmpty()) {
      appendLine("$option ${selection.selector}: no declaration matches.")
    } else {
      appendLine("$option ${selection.selector}: ${all.size} declarations match; pass one symbol ID:")
      for (sym in all) appendLine("  ${program.display(sym)}  =  $sym")
    }
    return false
  }

  private fun StringBuilder.hop(hop: Hop) {
    val call = program.calls[hop.edge.call]
    val more = if (hop.otherSites > 0) "  (+${hop.otherSites} more call sites)" else ""
    appendLine(
      "${hop.site ?: "?"}  ${program.display(hop.caller)}  --${describe(hop.edge.via, call)}-->  " +
        program.display(hop.callee) + more
    )
    if (hop.edge.via == "fnValue") {
      val witness = program.witnesses[hop.edge.call to hop.callee].orEmpty()
      appendLine("${INDENT}the value reaches the invoke over ${witness.size} flow edges:")
      for (flow in witness) flow(flow, INDENT)
    }
  }

  private fun StringBuilder.boundary(call: CallFact, otherSites: Int) {
    val more = if (otherSites > 0) "  (+$otherSites more call sites)" else ""
    appendLine(
      "${Site.of(call.id)}  ${program.display(call.callerDecl)}  --call [library]-->  " +
        program.display(call.target) + more
    )
  }

  private fun StringBuilder.flow(flow: FlowFact, indent: String) {
    appendLine(
      "$indent${Site.of(flow.at) ?: flow.at}  ${program.display(flow.from)}  " +
        "--flow [${flow.kind}]-->  ${program.display(flow.to)}"
    )
  }

  private fun describe(via: String, call: CallFact?): String =
    when (via) {
      "static" -> "call [static]"
      "cha" ->
        (program.chaCandidates[call?.id] ?: 0).let {
          "call [via cha, $it ${if (it == 1) "candidate" else "candidates"}]"
        }
      "fnValue" ->
        if (call?.dispatch == "invokeFnValue") {
          "call [via fnValue, fan-out ${program.fanOut[call.id] ?: 0}]"
        } else {
          "call [via fnValue, lambda as fun interface]"
        }
      "assumedInvoke" ->
        "assumedInvoke [lambda passed to ${call?.let { program.display(it.target) } ?: "?"}]"
      "init" -> "init"
      else -> "call [$via]"
    }

  private fun distancesTo(goals: Set<String>): Map<String, Int> {
    val callers = HashMap<String, MutableList<String>>()
    for ((caller, hops) in program.hops) {
      for (hop in hops) callers.getOrPut(hop.callee) { ArrayList() } += caller
    }
    val distance = HashMap<String, Int>()
    val queue = ArrayDeque<String>()
    for (goal in goals.sorted()) {
      distance[goal] = 0
      queue += goal
    }
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      for (caller in callers[current].orEmpty()) {
        if (caller !in distance) {
          distance[caller] = distance.getValue(current) + 1
          queue += caller
        }
      }
    }
    return distance
  }

  private fun StringBuilder.noPath(source: String, goalName: String, distance: Map<String, Int>) {
    appendLine("No path within ${options.maxDepth} hops.")
    val reachable = HashSet<String>()
    val queue = ArrayDeque(listOf(source))
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      if (reachable.add(current)) queue += program.hops[current].orEmpty().map { it.callee }
    }
    appendLine("${program.display(source)} reaches ${reachable.size} declarations.")
    appendLine("$goalName is reached from ${distance.size - 1} declarations.")
    val called = program.hops.values.flatten().map { it.callee }.toSet()
    val roots = distance.keys.filter { it !in called }.sortedBy { program.display(it) }
    if (roots.isNotEmpty()) {
      appendLine("Declarations that reach it and that nothing in the call graph calls:")
      for (root in roots.take(20)) {
        val decl = program.decls[root]
        appendLine("  ${decl?.file}:${decl?.span?.substringBefore(':')}  ${program.display(root)}  (${distance[root]} hops away)")
      }
      if (roots.size > 20) appendLine("  ${roots.size - 20} more are not printed.")
    }
  }
}

/** Enumerates simple paths in order of length, shortest first. */
private class PathSearch(
  private val program: Program,
  private val distance: Map<String, Int>,
  private val goals: Set<String>,
  private val options: TraceOptions,
) {
  var complete = true
    private set

  var stopReason = ""
    private set

  private var steps = 0
  private val found = ArrayList<List<Hop>>()

  fun run(source: String): List<List<Hop>> {
    val shortest = distance.getValue(source)
    for (length in shortest..options.maxDepth) {
      val onPath = LinkedHashSet<String>()
      onPath += source
      if (!extend(source, length, ArrayList(), onPath)) break
    }
    return found
  }

  /** Returns false when the search must stop. */
  private fun extend(
    current: String,
    remaining: Int,
    path: MutableList<Hop>,
    onPath: MutableSet<String>,
  ): Boolean {
    if (remaining == 0) {
      if (current in goals) {
        if (found.size >= options.pathLimit) {
          return stop("more than ${options.pathLimit} paths exist")
        }
        found += path.toList()
      }
      return true
    }
    for (hop in program.hops[current].orEmpty()) {
      if (++steps > options.searchBudget) {
        return stop("the budget of ${options.searchBudget} steps ran out at length ${path.size + remaining}")
      }
      val next = hop.callee
      val toGoal = distance[next] ?: continue
      if (toGoal > remaining - 1 || next in onPath) continue
      path += hop
      onPath += next
      val carryOn = extend(next, remaining - 1, path, onPath)
      path.removeLast()
      onPath -= next
      if (!carryOn) return false
    }
    return true
  }

  private fun stop(reason: String): Boolean {
    complete = false
    stopReason = reason
    return false
  }
}
