package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.CallEdgeFact
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
private const val PATH_COUNT_CAP = 1_000_000L

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

  /** The shortest chain of flow edges from one value to another. */
  fun traceValue(from: String, to: String): String = buildString {
    val start = program.selectValue(from, goal = false)
    val goal = program.selectValue(to, goal = true)
    if (!requireLocations(start, "--from") || !requireLocations(goal, "--to")) return@buildString
    appendLine("Value trace from ${start.label}")
    appendLine("              to ${goal.label}")
    appendLine()

    // Breadth-first by layer, counting the shortest paths into each location.
    val depth = LinkedHashMap<String, Int>()
    val paths = HashMap<String, Long>()
    val via = HashMap<String, FlowFact>()
    val counted = HashSet<Pair<String, String>>()
    val queue = ArrayDeque<String>()
    for (location in start.locations.sorted()) {
      depth[location] = 0
      paths[location] = 1
      queue += location
    }
    var found: String? = null
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      val next = depth.getValue(current) + 1
      if (found != null && next > depth.getValue(found)) break
      for (edge in program.valueEdges[current].orEmpty()) {
        val known = depth[edge.to]
        if (known == null) {
          depth[edge.to] = next
          paths[edge.to] = paths.getValue(current)
          via[edge.to] = edge
          counted += edge.from to edge.to
          queue += edge.to
          if (found == null && edge.to in goal.locations) found = edge.to
        } else if (known == next && counted.add(edge.from to edge.to)) {
          paths[edge.to] = minOf(paths.getValue(edge.to) + paths.getValue(current), PATH_COUNT_CAP)
        }
      }
    }
    val end = found ?: start.locations.sorted().firstOrNull { it in goal.locations }
    if (end == null) {
      appendLine("No path. The start reaches ${depth.size} locations.")
      val reaching = reachingGoal(goal.locations)
      appendLine("${reaching.size} locations reach the goal.")
      val frontier =
        depth.keys.filter { location -> program.valueEdges[location].isNullOrEmpty() }.sorted()
      appendLine("${frontier.size} reached locations have no outgoing edge. The first 40:")
      for (location in frontier.take(40)) appendLine("  ${program.display(location)}  =  $location")
      return@buildString
    }
    val hops = ArrayList<FlowFact>()
    var current: String = end
    while (true) {
      val edge = via[current] ?: break
      hops += edge
      current = edge.from
    }
    hops.reverse()
    val ends = goal.locations.filter { depth[it] == depth[end] }
    val count = ends.sumOf { paths[it] ?: 0 }
    val total = if (count >= PATH_COUNT_CAP) "at least $PATH_COUNT_CAP" else "$count"
    appendLine(
      "Shortest path: ${hops.size} hops. $total shortest paths exist; the first in sorted order is shown."
    )
    appendLine(
      "`N sources` after a hop counts the locations with an edge into its target, this one included."
    )
    appendLine()
    for (hop in hops) valueHop(hop)
  }

  private fun StringBuilder.valueHop(hop: FlowFact) {
    val rule = hop.ruleId?.let { " $it" }.orEmpty()
    val sources = program.valueSources[hop.to] ?: 1
    val note = if (sources > 1) "  ($sources sources)" else ""
    appendLine(
      "${Site.of(hop.at) ?: hop.at}  ${program.display(hop.from)}  --${hop.kind}$rule-->  " +
        program.display(hop.to) + note
    )
  }

  private fun reachingGoal(goals: Set<String>): Set<String> {
    val sources = HashMap<String, MutableList<String>>()
    for (edges in program.valueEdges.values) {
      for (edge in edges) sources.getOrPut(edge.to) { ArrayList() } += edge.from
    }
    val seen = HashSet(goals)
    val queue = ArrayDeque(goals.sorted())
    while (queue.isNotEmpty()) {
      for (source in sources[queue.removeFirst()].orEmpty()) if (seen.add(source)) queue += source
    }
    return seen
  }

  private fun StringBuilder.requireLocations(selection: ValueSelection, option: String): Boolean {
    if (selection.locations.isNotEmpty()) return true
    if (selection.candidates.isEmpty()) {
      appendLine("$option ${selection.label}: nothing matches.")
    } else {
      appendLine("$option ${selection.label}: ${selection.candidates.size} match; pass one ID:")
      for (candidate in selection.candidates) appendLine("  $candidate")
    }
    return false
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
        appendLine("$INDENT--${describe(edge, call)}-->  ${program.display(edge.callee)}")
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
      "${hop.site ?: "?"}  ${program.display(hop.caller)}  --${describe(hop.edge, call)}-->  " +
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
        "--flow [${flow.kind}${flow.ruleId?.let { " $it" }.orEmpty()}]-->  ${program.display(flow.to)}"
    )
  }

  private fun describe(edge: CallEdgeFact, call: CallFact?): String =
    when (val via = edge.via) {
      "invoke" ->
        "invoke [${edge.role} of ${edge.invoker?.let(program::display) ?: "?"}; ${edge.ruleId}]"
      "cell" -> {
        val cell = edge.cell?.let { program.cells[it] }
        val name =
          if (cell != null) "${cell.mechanism} ${cell.sym?.let(program::qualifiedName) ?: program.display(cell.id)}"
          else "stream ${edge.cell?.let(program::display)}"
        val through =
          when (edge.through) {
            0 -> ""
            1 -> ", through 1 operator"
            else -> ", through ${edge.through} operators"
          }
        "cell $name: ${edge.op}$through"
      }
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
