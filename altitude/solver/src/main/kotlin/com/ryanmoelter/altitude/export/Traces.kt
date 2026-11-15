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
class TraceRunner(
  private val program: Program,
  private val units: Units,
  private val members: Members,
  private val cellIndex: Map<String, Int>,
  private val options: TraceOptions = TraceOptions(),
) {
  fun run(query: GoldenQuery, edgeIndex: Map<Triple<String, String, String>, Int>, memberEdgeIndex: Map<Triple<String, String, String>, Int> = emptyMap()): TraceOut {
    val words = query.query.trim().split(Regex("\\s+"))
    val value = "--value" in words
    val opts = words.filter { it != "--value" && it != "--forward" }.chunked(2).associate { it[0] to it.getOrNull(1) }
    val from = opts["--from"]
    val to = opts["--to"]
    if (from == null || to == null) return TraceOut(query.name, query.query, query.comment, "unsupported", emptyList(), note = "only --from/--to queries are exported")
    val refs = Refs(edgeIndex, memberEdgeIndex)
    return if (value) valueTrace(query, from, to, opts["--via"]?.split(',').orEmpty(), refs)
    else callTrace(query, from, to, opts["--max-depth"]?.toInt() ?: options.maxDepth, refs)
  }

  private class Refs(val edges: Map<Triple<String, String, String>, Int>, val memberEdges: Map<Triple<String, String, String>, Int>)

  private fun node(location: String) = units.of(location)

  private fun edgeRef(index: Map<Triple<String, String, String>, Int>, from: String?, to: String?, vararg kinds: String): Int? {
    if (from == null || to == null || from == to) return null
    return kinds.firstNotNullOfOrNull { index[Triple(from, to, it)] }
  }

  // ---- call paths ----------------------------------------------------------------------------

  private fun callTrace(query: GoldenQuery, from: String, to: String, maxDepth: Int, refs: Refs): TraceOut {
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
      val ma = members.ofLocation(hop.caller)
      val mb = members.ofLocation(hop.callee)
      val kind = if (hop.edge.via == "di") "di" else "call"
      val edge = hop.edge
      val call = program.calls[edge.call]
      out +=
        TraceHopOut(
          from = hop.caller,
          to = hop.callee,
          kind = edge.via,
          site = hop.site?.toString(),
          rule = edge.ruleId,
          fromNode = a,
          toNode = b,
          edge = edgeRef(refs.edges, a, b, kind, "cellWrite"),
          fromMember = ma,
          toMember = mb,
          memberEdge = edgeRef(refs.memberEdges, ma, mb, kind),
          candidates = if (edge.via == "cha") program.chaCandidates[edge.call] ?: 0 else null,
          fanOut = if (edge.via == "fnValue" && call?.dispatch == "invokeFnValue") program.fanOut[edge.call] ?: 0 else null,
          witness = if (edge.via == "fnValue") program.witnesses[edge.call to edge.callee].orEmpty().size else null,
          otherSites = hop.otherSites,
          role = edge.role,
          invoker = edge.invoker,
          async = edge.via == "cell" || edge.role?.let { r -> ASYNC_ROLES.any { it in r } } == true,
          cell = edge.cell?.let(cellIndex::get),
          cellOp = edge.op,
          through = edge.through,
          nonProduction = program.isStaged(hop.callee),
        )
      rendered += "${hop.site ?: "?"}  ${program.display(hop.caller)}  --" to "-->  ${program.display(hop.callee)}"
    }
    if (libraryGoal != null) {
      val last = hops.lastOrNull()?.callee ?: source
      val calls = ends.getValue(last)
      val call = calls.first()
      out += TraceHopOut(last, call.target, "library", Site.of(call.id)?.toString(), fromNode = node(last), fromMember = members.ofLocation(last), otherSites = calls.size - 1)
      rendered += "${Site.of(call.id)}  ${program.display(call.callerDecl)}  --call [library]" to "-->  ${program.display(call.target)}"
    }
    val goldenLines = query.golden?.let { lines -> hopLines(lines) }
    val matches = goldenLines?.let { g -> g.size == rendered.size && g.zip(rendered).all { (line, r) -> line.startsWith(r.first) && r.second in line } }
    val count = countPaths(source, distance, ends.keys, shortest, maxDepth)
    val length = out.size
    val leg =
      TraceLegOut(
        source, libraryGoal ?: goal.decls.single(), out, nodePath(out),
        cost = CostOut(length = length),
        costText = "$length hops",
        paths = count.total,
        equalCostPaths = count.shortest.toLong(),
        countsIncomplete = !count.complete,
      )
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

  private class PathCount(val total: Int, val shortest: Int, val complete: Boolean)

  /** The tracer's path enumeration, counted rather than kept: simple paths by length, up to its limits. */
  private fun countPaths(source: String, distance: Map<String, Int>, goals: Set<String>, shortest: Int, maxDepth: Int): PathCount {
    var found = 0
    var atShortest = 0
    var steps = 0
    var complete = true
    fun walk(current: String, remaining: Int, onPath: MutableSet<String>, length: Int): Boolean {
      if (remaining == 0) {
        if (current in goals) {
          if (found >= options.pathLimit) return false.also { complete = false }
          found++
          if (length == shortest) atShortest++
        }
        return true
      }
      for (hop in program.hops[current].orEmpty()) {
        if (++steps > options.searchBudget) return false.also { complete = false }
        val next = hop.callee
        val toGoal = distance[next] ?: continue
        if (toGoal > remaining - 1 || next in onPath) continue
        onPath += next
        val carryOn = walk(next, remaining - 1, onPath, length)
        onPath -= next
        if (!carryOn) return false
      }
      return true
    }
    for (length in shortest..maxDepth) if (!walk(source, length, linkedSetOf(source), length)) break
    return PathCount(found, atShortest, complete)
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

  /** [projected] is each hop's starting state's projection, which some hop notes depend on. */
  private class Leg(val hops: List<FlowFact>, val projected: List<String?>, val cost: PathCost, val equalCost: Long, val exhausted: Boolean)

  private fun valueTrace(query: GoldenQuery, from: String, to: String, via: List<String>, refs: Refs): TraceOut {
    val stops = listOf(from) + via + to
    val starts = stops.dropLast(1).map { program.selectValue(it, goal = false) }
    val goals = stops.drop(1).map { program.selectValue(it, goal = true) }
    if ((starts + goals.last()).any { it.locations.isEmpty() }) return TraceOut(query.name, query.query, query.comment, "value", emptyList(), note = "a value selector matches nothing")
    val legs = ArrayList<TraceLegOut>()
    val rendered = ArrayList<String>()
    var found = true
    for (i in starts.indices) {
      val leg = valueLeg(starts[i].locations, goals[i].locations)
      if (leg == null) {
        found = false
        legs += TraceLegOut(stops[i], stops[i + 1], emptyList(), emptyList())
        continue
      }
      var depth = 0
      val out =
        leg.hops.mapIndexed { index, hop ->
          depth +=
            when {
              hop.kind == "partOf" || hop.kind == "heldBy" -> 1
              hop.kind == "memberOf" || (hop.kind == "contentOf" && hop.to.endsWith(ELEMENT)) -> -1
              else -> 0
            }
          rendered += "${Site.of(hop.at) ?: hop.at}  ${program.display(hop.from)}  --${hop.kind}${hop.ruleId?.let { " $it" }.orEmpty()}-->  ${program.display(hop.to)}"
          valueHop(hop, leg.projected[index], depth, refs)
        }
      val skeleton =
        (listOf(starts[i].label) + leg.hops.mapNotNull { program.landmark(it) } + goals[i].label).fold(ArrayList<String>()) { kept, stop ->
          if (kept.lastOrNull() != stop) kept += stop
          kept
        }
      val c = leg.cost
      legs +=
        TraceLegOut(
          stops[i], stops[i + 1], out, nodePath(out),
          cost = CostOut(c.anyInstanceReads, c.stagedHops, c.conflation, c.derivedHops, c.length),
          costText = c.describe(),
          equalCostPaths = leg.equalCost,
          countsIncomplete = leg.exhausted || leg.equalCost >= PATH_COUNT_CAP,
          skeleton = skeleton,
        )
    }
    val goldenLines = query.golden?.let { hopLines(it) }
    val matches = goldenLines?.let { g -> found && g.size == rendered.size && g.zip(rendered).all { (line, r) -> line.startsWith(r) } }
    return TraceOut(query.name, query.query, query.comment, "value", legs, matches, if (found) null else "a leg has no path")
  }

  private fun valueHop(hop: FlowFact, projected: String?, depth: Int, refs: Refs): TraceHopOut {
    val a = node(hop.from)
    val b = node(hop.to)
    val ma = members.ofLocation(hop.from)
    val mb = members.ofLocation(hop.to)
    val moves = hop.kind !in DERIVED_KINDS
    val kinds = if (hop.kind == "di") arrayOf("di") else if (!moves) emptyArray() else arrayOf("value", "cellWrite", "cellRead")
    val choices = if (hop.kind == "contentOf") program.valueEdges[hop.from].orEmpty().count { it.kind == "contentOf" } else 0
    return TraceHopOut(
      from = withoutContext(hop.from),
      to = withoutContext(hop.to),
      kind = hop.kind,
      site = (Site.of(hop.at) ?: siteOf(hop.at, units))?.toString(),
      rule = hop.ruleId,
      fromNode = a,
      toNode = b,
      edge = edgeRef(refs.edges, a, b, *kinds),
      wrapDepth = depth,
      fromMember = ma,
      toMember = mb,
      memberEdge = edgeRef(refs.memberEdges, ma, mb, *kinds),
      cell = cellOf(hop.to),
      fromCell = cellOf(hop.from),
      construction = hop.kind == "partOf",
      projection = hop.kind == "memberOf",
      container = hop.kind == "contentOf",
      containerChoices = choices.takeIf { it > 1 },
      heldBy = hop.kind == "heldBy",
      fanIn = if (moves) program.fanIn[hop.to]?.takeIf { it > 1 } else null,
      anyContainer = program.readsAnyContainer(hop, projected),
      anyInstanceOf = if (program.isSharedByInstances(hop.from)) units.decls[hop.from]?.name else null,
      property = if (hop.kind == "memberOf") propertyRead(hop.to) else null,
      nonProduction = program.isStaged(hop.to),
      landmark = program.landmark(hop),
    )
  }

  private fun cellOf(location: String): Int? {
    if (!location.endsWith(ELEMENT)) return null
    return program.cellAt(location.removeSuffix(ELEMENT))?.let { cellIndex[it.id] }
  }

  private fun propertyRead(location: String): String? {
    val target = units.nodesById[withoutContext(location)]?.target ?: return null
    return units.decls[target]?.name ?: target.substringBefore("#<").substringBefore('(').substringAfterLast('/').substringAfterLast('.')
  }

  /** The search of `trace --value`: cheapest first, ties broken by the order states were reached. */
  private fun valueLeg(start: Set<String>, goal: Set<String>): Leg? {
    val best = HashMap<State, PathCost>()
    val paths = HashMap<State, Long>()
    val via = HashMap<State, Pair<State, FlowFact>>()
    val settled = HashSet<State>()
    val order = HashMap<State, Int>()
    val queue = PriorityQueue<Queued>(compareBy<Queued> { it.cost }.thenBy { it.rank })
    for (location in start.sorted()) {
      val state = State(location, emptyList())
      order[state] = order.size
      best[state] = PathCost.ZERO
      paths[state] = 1
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
        val comparison = if (known == null) -1 else next.compareTo(known)
        if (comparison < 0) {
          val rank = order.getOrPut(target) { order.size }
          best[target] = next
          paths[target] = paths.getValue(current)
          via[target] = current to edge
          queue += Queued(next, rank, target)
          if (edge.to in goal) {
            val held = reachedAtGoal
            if (held == null || next < best.getValue(held)) reachedAtGoal = target
          }
        } else if (comparison == 0) {
          paths[target] = minOf(paths.getValue(target) + paths.getValue(current), PATH_COUNT_CAP)
        }
      }
    }
    val exhausted = end == null && steps > options.searchBudget
    if (exhausted) end = reachedAtGoal
    val last = end ?: return null
    val hops = ArrayList<FlowFact>()
    val projected = ArrayList<String?>()
    var current: State = last
    while (true) {
      val (previous, edge) = via[current] ?: break
      hops += edge
      projected += previous.projected
      current = previous
    }
    return Leg(hops.reversed(), projected.reversed(), best.getValue(last), paths.getValue(last), exhausted)
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

/** The tracer's cap on a counted number of equal-cost paths. */
private const val PATH_COUNT_CAP = 1_000_000L

/** Flow kinds that derive one value from another rather than move it. */
private val DERIVED_KINDS = setOf("memberOf", "partOf", "contentOf", "heldBy")

/** Model role wording for a lambda the invoker runs after the call returns. */
private val ASYNC_ROLES = listOf("asynchronously", "in a coroutine")
