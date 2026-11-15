package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.solver.withoutContext
import com.ryanmoelter.altitude.trace.Hop
import com.ryanmoelter.altitude.trace.PathCost
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.Site
import com.ryanmoelter.altitude.trace.TraceOptions
import java.nio.file.Path
import java.util.PriorityQueue
import kotlin.io.path.exists
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.name
import kotlin.io.path.readLines

/** One line of a `golden/<target>/<name>.queries` file, with the comment lines above it. */
data class GoldenQuery(val name: String, val query: String, val comment: String?, val golden: List<String>?)

/** Reads every query of a golden directory, paired with its section of the `.trace.txt` file. */
fun readGolden(dir: Path): List<GoldenQuery> {
  if (!dir.exists()) return emptyList()
  val out = ArrayList<GoldenQuery>()
  for (file in dir.listDirectoryEntries("*.queries").sortedBy { it.name }) {
    val name = file.name.removeSuffix(".queries")
    val text = dir.resolve("$name.trace.txt").takeIf { it.exists() }?.readLines()
    val sections = HashMap<String, MutableList<String>>()
    var current: MutableList<String>? = null
    for (line in text.orEmpty()) {
      if (line.startsWith("\$ altitude trace ")) current = sections.getOrPut(line.removePrefix("\$ altitude trace ")) { ArrayList() }
      else current?.add(line)
    }
    val comment = ArrayList<String>()
    var index = 0
    for (line in file.readLines()) {
      when {
        line.startsWith("#") -> comment += line.removePrefix("#").trim()
        line.isBlank() -> comment.clear()
        else -> {
          index++
          out += GoldenQuery("$name#$index", line, comment.joinToString(" ").ifEmpty { null }, sections[line])
          comment.clear()
        }
      }
    }
  }
  return out
}

/**
 * Reruns the call and value searches of `trace` and keeps each hop as data. The searches are the
 * same as [com.ryanmoelter.altitude.trace.Tracer]'s, and [TraceOut.matchesGolden] checks them
 * against the golden text, so the export carries the path the golden trace prints.
 */
class TraceRunner(private val program: Program, private val units: Units, private val options: TraceOptions = TraceOptions()) {
  fun run(query: GoldenQuery, edgeIndex: Map<Triple<String, String, String>, Int>): TraceOut {
    val words = query.query.trim().split(Regex("\\s+"))
    val value = "--value" in words
    val opts = words.filter { it != "--value" && it != "--forward" }.chunked(2).associate { it[0] to it.getOrNull(1) }
    val from = opts["--from"]
    val to = opts["--to"]
    if (from == null || to == null) return TraceOut(query.name, query.query, query.comment, "unsupported", emptyList(), note = "only --from/--to queries are exported")
    return if (value) valueTrace(query, from, to, opts["--via"]?.split(',').orEmpty(), edgeIndex)
    else callTrace(query, from, to, opts["--max-depth"]?.toInt() ?: options.maxDepth, edgeIndex)
  }

  private fun node(location: String) = units.of(location)

  private fun edgeRef(edgeIndex: Map<Triple<String, String, String>, Int>, from: String?, to: String?, vararg kinds: String): Int? {
    if (from == null || to == null || from == to) return null
    return kinds.firstNotNullOfOrNull { edgeIndex[Triple(from, to, it)] }
  }

  // ---- call paths ----------------------------------------------------------------------------

  private fun callTrace(query: GoldenQuery, from: String, to: String, maxDepth: Int, edgeIndex: Map<Triple<String, String, String>, Int>): TraceOut {
    val start = program.select(from)
    val goal = program.select(to, includeLibrary = true)
    if (!start.isUnique || !goal.isUnique) return TraceOut(query.name, query.query, query.comment, "call", emptyList(), note = "selector is not unique")
    val source = start.decls.single()
    val libraryGoal = goal.library.singleOrNull()
    val ends: Map<String, List<CallFact>> =
      if (libraryGoal != null) program.boundaryCalls.mapValues { (_, c) -> c.filter { it.target == libraryGoal } }.filterValues { it.isNotEmpty() }
      else program.constructorsOf(goal.decls.single()).ifEmpty { goal.decls }.associateWith { emptyList() }
    val distance = distancesTo(ends.keys)
    val shortest = distance[source]
    if (shortest == null || shortest > maxDepth) return TraceOut(query.name, query.query, query.comment, "call", emptyList(), matchesGolden = query.golden?.let { false }, note = "no path")
    val path = ArrayList<Hop>()
    check(extend(source, shortest, path, linkedSetOf(source), distance, ends.keys)) { "a path of length $shortest exists" }
    val hops = path.mapIndexed { i, hop -> program.siteFor(hop, path.getOrNull(i + 1)) }
    val out = ArrayList<TraceHopOut>()
    val rendered = ArrayList<Pair<String, String>>()
    for (hop in hops) {
      val a = node(hop.caller)
      val b = node(hop.callee)
      val kind = if (hop.edge.via == "di") "di" else "call"
      out += TraceHopOut(hop.caller, hop.callee, hop.edge.via, hop.site?.toString(), hop.edge.ruleId, a, b, edgeRef(edgeIndex, a, b, kind, "cellWrite"))
      rendered += "${hop.site ?: "?"}  ${program.display(hop.caller)}  --" to "-->  ${program.display(hop.callee)}"
    }
    if (libraryGoal != null) {
      val last = hops.lastOrNull()?.callee ?: source
      val call = ends.getValue(last).first()
      out += TraceHopOut(last, call.target, "library", Site.of(call.id)?.toString(), fromNode = node(last))
      rendered += "${Site.of(call.id)}  ${program.display(call.callerDecl)}  --call [library]" to "-->  ${program.display(call.target)}"
    }
    val goldenLines = query.golden?.let { lines -> hopLines(lines) }
    val matches = goldenLines?.let { g -> g.size == rendered.size && g.zip(rendered).all { (line, r) -> line.startsWith(r.first) && r.second in line } }
    val leg = TraceLegOut(source, libraryGoal ?: goal.decls.single(), out, nodePath(out))
    return TraceOut(query.name, query.query, query.comment, "call", listOf(leg), matches)
  }

  private fun extend(current: String, remaining: Int, path: MutableList<Hop>, onPath: MutableSet<String>, distance: Map<String, Int>, goals: Set<String>): Boolean {
    if (remaining == 0) return current in goals
    for (hop in program.hops[current].orEmpty()) {
      val next = hop.callee
      val toGoal = distance[next] ?: continue
      if (toGoal > remaining - 1 || next in onPath) continue
      path += hop
      onPath += next
      if (extend(next, remaining - 1, path, onPath, distance, goals)) return true
      path.removeLast()
      onPath -= next
    }
    return false
  }

  private fun distancesTo(goals: Set<String>): Map<String, Int> {
    val callers = HashMap<String, MutableList<String>>()
    for ((caller, hops) in program.hops) for (hop in hops) callers.getOrPut(hop.callee) { ArrayList() } += caller
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

  // ---- value paths ---------------------------------------------------------------------------

  private data class State(val location: String, val calls: List<String>, val projected: String? = null, val filled: String? = null)

  private class Queued(val cost: PathCost, val rank: Int, val state: State)

  private fun valueTrace(query: GoldenQuery, from: String, to: String, via: List<String>, edgeIndex: Map<Triple<String, String, String>, Int>): TraceOut {
    val stops = listOf(from) + via + to
    val starts = stops.dropLast(1).map { program.selectValue(it, goal = false) }
    val goals = stops.drop(1).map { program.selectValue(it, goal = true) }
    if ((starts + goals.last()).any { it.locations.isEmpty() }) return TraceOut(query.name, query.query, query.comment, "value", emptyList(), note = "a value selector matches nothing")
    val legs = ArrayList<TraceLegOut>()
    val rendered = ArrayList<String>()
    var found = true
    for (i in starts.indices) {
      val hops = valueLeg(starts[i].locations, goals[i].locations)
      if (hops == null) {
        found = false
        legs += TraceLegOut(stops[i], stops[i + 1], emptyList(), emptyList())
        continue
      }
      var depth = 0
      val out =
        hops.map { hop ->
          depth +=
            when {
              hop.kind == "partOf" || hop.kind == "heldBy" -> 1
              hop.kind == "memberOf" || (hop.kind == "contentOf" && hop.to.endsWith(ELEMENT)) -> -1
              else -> 0
            }
          val a = node(hop.from)
          val b = node(hop.to)
          val kinds = if (hop.kind == "di") arrayOf("di") else if (hop.kind in setOf("memberOf", "partOf", "contentOf", "heldBy")) emptyArray() else arrayOf("value", "cellWrite", "cellRead")
          rendered += "${Site.of(hop.at) ?: hop.at}  ${program.display(hop.from)}  --${hop.kind}${hop.ruleId?.let { " $it" }.orEmpty()}-->  ${program.display(hop.to)}"
          TraceHopOut(withoutContext(hop.from), withoutContext(hop.to), hop.kind, (Site.of(hop.at) ?: siteOf(hop.at, units))?.toString(), hop.ruleId, a, b, edgeRef(edgeIndex, a, b, *kinds), depth)
        }
      legs += TraceLegOut(stops[i], stops[i + 1], out, nodePath(out))
    }
    val goldenLines = query.golden?.let { hopLines(it) }
    val matches = goldenLines?.let { g -> found && g.size == rendered.size && g.zip(rendered).all { (line, r) -> line.startsWith(r) } }
    return TraceOut(query.name, query.query, query.comment, "value", legs, matches, if (found) null else "a leg has no path")
  }

  /** The search of `trace --value`: cheapest first, ties broken by the order states were reached. */
  private fun valueLeg(start: Set<String>, goal: Set<String>): List<FlowFact>? {
    val best = HashMap<State, PathCost>()
    val via = HashMap<State, Pair<State, FlowFact>>()
    val settled = HashSet<State>()
    val order = HashMap<State, Int>()
    val queue = PriorityQueue<Queued>(compareBy<Queued> { it.cost }.thenBy { it.rank })
    for (location in start.sorted()) {
      val state = State(location, emptyList())
      order[state] = order.size
      best[state] = PathCost.ZERO
      queue += Queued(PathCost.ZERO, order.getValue(state), state)
    }
    var end: State? = null
    var steps = 0
    var reachedAtGoal: State? = null
    search@ while (queue.isNotEmpty()) {
      val q = queue.poll()
      val current = q.state
      if (q.cost != best[current] || !settled.add(current)) continue
      if (current.location in goal) {
        end = current
        break
      }
      for (edge in program.valueEdges[current.location].orEmpty()) {
        if (++steps > options.searchBudget) break@search
        val calls = program.callsAfter(current.calls, edge, current.projected, current.filled) ?: continue
        val target = State(edge.to, calls, program.projects(edge), program.fills(edge))
        if (target in settled) continue
        val next = q.cost + program.hopCost(edge, current.projected)
        val known = best[target]
        if (known == null || next < known) {
          val rank = order.getOrPut(target) { order.size }
          best[target] = next
          via[target] = current to edge
          queue += Queued(next, rank, target)
          if (edge.to in goal) {
            val held = reachedAtGoal
            if (held == null || next < best.getValue(held)) reachedAtGoal = target
          }
        }
      }
    }
    if (end == null && steps > options.searchBudget) end = reachedAtGoal
    var current = end ?: return null
    val hops = ArrayList<FlowFact>()
    while (true) {
      val (previous, edge) = via[current] ?: break
      hops += edge
      current = previous
    }
    return hops.reversed()
  }

  private fun nodePath(hops: List<TraceHopOut>): List<String> =
    hops.flatMap { listOfNotNull(it.fromNode, it.toNode) }.fold(ArrayList()) { kept, n ->
      if (kept.lastOrNull() != n) kept += n
      kept
    }

  /** The hop lines of a golden section: unindented `<site>  <from>  --<kind>-->  <to>` lines. */
  private fun hopLines(lines: List<String>): List<String> =
    lines.filter { line -> !line.startsWith(" ") && "  --" in line && "-->  " in line && !line.startsWith("Skeleton:") }
}
