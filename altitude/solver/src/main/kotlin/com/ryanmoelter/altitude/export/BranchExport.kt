package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.CellFact
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.rules.Rules
import com.ryanmoelter.altitude.solver.withoutContext
import com.ryanmoelter.altitude.trace.BranchOptions
import com.ryanmoelter.altitude.trace.BranchSearch
import com.ryanmoelter.altitude.trace.BranchTree
import com.ryanmoelter.altitude.trace.Direction
import com.ryanmoelter.altitude.trace.PATH_COUNT_CAP
import com.ryanmoelter.altitude.trace.PathCost
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.TerminalKey
import com.ryanmoelter.altitude.trace.Terminals
import com.ryanmoelter.altitude.trace.valueHopLine

const val BRANCHES_FILE = "altitude-branches.json"

/** The locations and hop records the trees of one branches file share, each kept once. */
class BranchTables {
  private val locs = LinkedHashMap<String, Int>()
  private val hops = LinkedHashMap<TraceHopOut, Int>()

  fun loc(location: String): Int = locs.getOrPut(location) { locs.size }

  fun hop(record: TraceHopOut): Int = hops.getOrPut(record) { hops.size }

  fun export(target: String, trees: List<BranchTreeOut>, counts: Map<String, Int>) =
    BranchesExport(target = target, locs = locs.keys.toList(), hops = hops.keys.toList(), trees = trees, counts = counts)
}

/** Where a branch tree starts: the root's locations, and what they stand for. */
class BranchRoot(val direction: Direction, val kind: String, val ref: Int?, val label: String, val locations: Set<String>)

/** Terminal kinds a path stops at by default. */
fun defaultStops(direction: Direction, throughCells: Boolean): Set<String> =
  when (direction) {
    Direction.FORWARD -> setOf("boundary", "cellWrite", "ui")
    Direction.BACKWARD -> setOf("boundary", "cellRead", "entry")
  }.filterTo(sortedSetOf()) { !throughCells || !it.startsWith("cell") }

/** Classifies terminals and renders branch trees against the indices of the export files. */
class BranchContext(
  val program: Program,
  private val facts: Facts,
  private val rules: Rules,
  private val units: Units,
  private val members: Members,
  private val composable: Set<String>,
  private val cellFacts: List<CellFact>,
  private val memberIndex: Map<String, Int>,
  private val nodeIndex: Map<String, Int>,
  private val refs: TraceRunner.Refs,
  /** States a backward tree's reachability graph may hold. */
  private val backwardStates: Int = 3_000_000,
) {
  private val cellIndex: Map<String, Int> = cellFacts.withIndex().associate { it.value.id to it.index }
  private val runner = TraceRunner(program, units, members, cellIndex)
  private val search = BranchSearch(program)
  private val callsById = facts.calls.associateBy { it.id }
  private val argsByCall = facts.args.groupBy({ it.call }, { it.node })

  private fun inputsOf(callId: String): List<String> {
    val call = callsById[callId] ?: return emptyList()
    return argsByCall[callId].orEmpty() + call.receiver + call.extReceiver
  }

  private val boundaryInputs = HashMap<String, Int>().apply {
    for ((i, b) in rules.boundaries.withIndex()) for (l in inputsOf(b.call)) putIfAbsent(l, i)
  }
  private val boundaryResults = HashMap<String, Int>().apply {
    for ((i, b) in rules.boundaries.withIndex()) callsById[b.call]?.result?.let { putIfAbsent(it, i) }
  }
  private val entries = HashMap<String, Int>().apply { for ((i, e) in rules.entrypoints.withIndex()) putIfAbsent(e.sym, i) }
  private val libraryInputs: Set<String> = facts.calls.filter { !it.targetInSource }.flatMapTo(HashSet()) { inputsOf(it.id) }

  private fun cellOf(id: String): Int? =
    if (id.endsWith(ELEMENT)) program.cellAt(id.removeSuffix(ELEMENT))?.let { cellIndex[it.id] } else null

  private fun forward(location: String, rootMembers: Set<String>): TerminalKey? {
    val id = withoutContext(location)
    boundaryInputs[id]?.let { return TerminalKey("boundary", it) }
    cellOf(id)?.let { return TerminalKey("cellWrite", it) }
    val member = members.ofLocation(id)
    if (member != null && member in composable && member !in rootMembers) memberIndex[member]?.let { return TerminalKey("ui", it) }
    if (id in libraryInputs && program.valueEdges[location].isNullOrEmpty()) member?.let(memberIndex::get)?.let { return TerminalKey("sink", it) }
    return null
  }

  private fun backward(location: String): TerminalKey? {
    val id = withoutContext(location)
    boundaryResults[id]?.let { return TerminalKey("boundary", it) }
    cellOf(id)?.let { return TerminalKey("cellRead", it) }
    val part = id.indexOf('#')
    if (part > 0) entries[id.substring(0, part)]?.let { return TerminalKey("entry", it) }
    return null
  }

  /** Every root the export precomputes a tree for. */
  fun roots(golden: List<GoldenQuery>): List<BranchRoot> = buildList {
    for ((i, cell) in cellFacts.withIndex()) add(BranchRoot(Direction.FORWARD, "cell", i, program.cellName(cell), program.cellSlots(cell.id)))
    for ((i, b) in rules.boundaries.withIndex()) {
      val results = program.callResults(b.call)
      if (results.isNotEmpty()) add(BranchRoot(Direction.FORWARD, "boundary", i, boundaryLabel(i), results))
    }
    for ((i, b) in rules.boundaries.withIndex()) {
      val inputs = program.callInputs(b.call)
      if (inputs.isNotEmpty()) add(BranchRoot(Direction.BACKWARD, "boundary", i, boundaryLabel(i), inputs))
    }
    for (query in golden) {
      val words = query.query.trim().split(Regex("\\s+"))
      if ("--value" !in words) continue
      val opts = words.filter { !it.startsWith("--") || it in VALUE_OPTIONS }.chunked(2).associate { it[0] to it.getOrNull(1) }
      val from = opts["--from"]?.let { program.selectValue(it, goal = false) }
      val to = opts["--to"]?.let { program.selectValue(it, goal = true) }
      if (from != null && from.locations.isNotEmpty()) add(BranchRoot(Direction.FORWARD, "traceEnd", null, "${query.name} from ${from.label}", from.locations))
      if (to != null && to.locations.isNotEmpty()) add(BranchRoot(Direction.BACKWARD, "traceEnd", null, "${query.name} to ${to.label}", to.locations))
    }
  }

  fun tree(root: BranchRoot, stops: Set<String>, clean: Boolean = false): BranchTree {
    val rootMembers = root.locations.mapNotNullTo(HashSet()) { members.ofLocation(it) }
    val terminals =
      when (root.direction) {
        Direction.FORWARD -> Terminals { forward(it, rootMembers) }
        Direction.BACKWARD -> Terminals(::backward)
      }
    val result = search.search(root.direction, root.locations, terminals, BranchOptions(stops, backwardStates = backwardStates))
    val paths = if (clean) result.paths.filter { it.clean } else result.paths
    return BranchTree(root.direction, root.locations, stops, result.truncated, paths, program)
  }

  private fun rootLocation(root: BranchRoot): String = root.locations.minOf { withoutContext(it) }

  private fun memberOf(location: String): Int? = members.ofLocation(location)?.let(memberIndex::get)

  private fun nodeOf(location: String): Int? = units.of(location)?.let(nodeIndex::get)

  /** [withHops] false leaves the hop records of segments that are not clean out of the file. */
  fun out(root: BranchRoot, tree: BranchTree, clean: Boolean, tables: BranchTables, withHops: Boolean = true): BranchTreeOut {
    val records = arrayOfNulls<TraceHopOut>(tree.nodes.size)
    for (terminal in tree.terminals) {
      val path = terminal.path
      val hops = runner.valueHops(path.hops, path.states.dropLast(1).map { it.projected }, refs)
      for ((i, node) in tree.hopNodes(terminal).withIndex()) {
        val known = records[node]
        records[node] = if (known == null) hops[i] else if (hops[i].fieldMismatch && !known.fieldMismatch) known.copy(fieldMismatch = true) else known
      }
    }
    val drafts =
      tree.segments.map { segment ->
        var cost = PathCost.ZERO
        val approx = sortedSetOf<String>()
        val memberPath = ArrayList<Int>()
        for (n in segment.hops) {
          val node = tree.nodes[n]
          val edge = node.step!!
          val projected = node.upstream!!.projected
          cost += program.hopCost(edge, projected)
          if (program.isSharedByInstances(edge.from)) approx += "anyInstance"
          if (program.readsAnyContainer(edge, projected)) approx += "anyContainer"
          if (records[n]?.fieldMismatch == true) approx += "fieldMismatch"
          if (program.isStaged(edge.to)) approx += "staged"
          for (location in listOf(edge.from, edge.to)) memberOf(location)?.let { if (memberPath.lastOrNull() != it) memberPath += it }
        }
        val keep = withHops || (cost.anyInstanceReads == 0 && cost.stagedHops == 0)
        Triple(segment, keep, BranchSegmentOut(segment.a, segment.b, null, segment.hops.size, memberPath, cost.out(), approx.toList()))
      }
    val segments = drafts.map { (segment, keep, out) -> if (keep) out.copy(hops = segment.hops.map { tables.hop(records[it]!!) }) else out }
    val points =
      tree.points.map { p ->
        val location = if (p.node == 0) rootLocation(root) else withoutContext(tree.nodes[p.node].state!!.location)
        BranchPointOut(memberOf(location), nodeOf(location), tables.loc(location), p.kind)
      }
    val terminals =
      tree.terminals.map { t ->
        BranchTerminalOut(t.point, t.path.key.kind, t.path.key.ref, t.path.cost.out(), minOf(t.path.equalCost, PATH_COUNT_CAP), t.path.clean, t.segments)
      }
    val siblings =
      tree.siblings.map { s -> BranchSiblingOut(s.point, s.kind, s.values.map { BranchSiblingValueOut(tables.loc(it.location), memberOf(it.location), it.name) }) }
    val rootLoc = rootLocation(root)
    return BranchTreeOut(
      root = BranchRootOut(tables.loc(rootLoc), memberOf(rootLoc), nodeOf(rootLoc), root.direction.label, root.kind, root.ref, root.label),
      options = BranchOptionsOut(tree.stops.toList(), clean = clean),
      truncated = tree.truncated,
      points = points,
      segments = segments,
      terminals = terminals,
      siblings = siblings,
    )
  }

  fun label(key: TerminalKey, memberIds: List<String>): String =
    when (key.kind) {
      "boundary" -> boundaryLabel(key.ref)
      "cellWrite", "cellRead" -> program.cellName(cellFacts[key.ref])
      "entry" -> rules.entrypoints[key.ref].let { "${it.kind} ${program.display(it.sym)}" }
      else -> program.display(memberIds[key.ref])
    }

  private fun boundaryLabel(i: Int): String {
    val b = rules.boundaries[i]
    return "${b.system}:${b.kind} ${b.label ?: program.display(b.target)}"
  }

  /** The tree as text: its terminals, then each segment's hops under the point it leaves. */
  fun text(root: BranchRoot, tree: BranchTree, memberIds: List<String>): String = buildString {
    val clean = tree.terminals.count { it.path.clean }
    appendLine("Branches ${root.direction.label} from ${root.label}")
    appendLine("Stops: ${tree.stops.joinToString().ifEmpty { "none" }}.")
    appendLine("${tree.terminals.size} terminals, $clean clean; ${tree.points.size} points, ${tree.segments.size} segments, ${tree.nodes.size - 1} hops.")
    if (tree.truncated) appendLine("A search stopped at its cap, so terminals may be missing.")
    appendLine(
      "Each terminal's path is the one `trace --value` prints between the root and that terminal. " +
        "A path that passes a stop is left out. Hops print in data-flow order under the point nearer the root."
    )
    appendLine()
    appendLine("Terminals:")
    val terminalOfPoint = HashMap<Int, Int>()
    for ((i, t) in tree.terminals.withIndex()) {
      terminalOfPoint[t.point] = i
      val count = if (t.path.equalCost >= PATH_COUNT_CAP) "at least $PATH_COUNT_CAP" else "${t.path.equalCost}"
      appendLine("  T${i + 1}  ${t.path.key.kind}  ${label(t.path.key, memberIds)}  ${if (t.path.clean) "clean" else "approximate"}; ${t.path.cost.describe()}; $count paths")
    }
    appendLine()
    appendLine("Tree:")
    val children = HashMap<Int, MutableList<Int>>()
    for ((i, s) in tree.segments.withIndex()) children.getOrPut(if (root.direction == Direction.FORWARD) s.a else s.b) { ArrayList() } += i
    appendLine("root  ${root.label}")
    fun walk(point: Int, indent: String) {
      val out = children[point].orEmpty()
      val inner = if (out.size > 1) "$indent  " else indent
      for (s in out) {
        val segment = tree.segments[s]
        if (out.size > 1) appendLine("$indent+ branch ${out.indexOf(s) + 1} of ${out.size}")
        for (n in segment.hops) {
          val node = tree.nodes[n]
          appendLine(inner + program.valueHopLine(node.step!!, node.upstream!!.projected, node.fieldMismatch))
        }
        val far = if (root.direction == Direction.FORWARD) segment.b else segment.a
        val p = tree.points[far]
        val terminal = terminalOfPoint[far]?.let { "  T${it + 1}" }.orEmpty()
        appendLine("$inner* ${p.kind}$terminal  ${program.display(tree.nodes[p.node].state!!.location)}")
        walk(far, inner)
      }
    }
    walk(0, "")
  }

  companion object {
    private val VALUE_OPTIONS = setOf("--from", "--to", "--via")
  }
}

private fun PathCost.out() = CostOut(anyInstanceReads, stagedHops, conflation, derivedHops, length)
