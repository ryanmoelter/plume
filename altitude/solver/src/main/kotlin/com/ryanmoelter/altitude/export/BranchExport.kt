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
const val BRANCH_SINKS_FILE = "altitude-branch-sinks.json"

/** The locations, strings and hop records the trees of one file share, each kept once. */
class BranchTables(private val fileIndex: Map<String, Int> = emptyMap()) {
  private val locs = LinkedHashMap<String, Int>()
  private val strs = LinkedHashMap<String, Int>()
  private val hops = LinkedHashMap<BranchHopOut, Int>()

  fun loc(location: String): Int = locs.getOrPut(location) { locs.size }

  private fun str(value: String?): Int? = value?.let { strs.getOrPut(it) { strs.size } }

  private fun site(site: String?): String? {
    site ?: return null
    val path = site.substringBeforeLast(':')
    return fileIndex[path]?.let { "$it:${site.substringAfterLast(':')}" } ?: site
  }

  fun hop(h: TraceHopOut, memberIndex: Map<String, Int>): Int {
    val flags = (if (h.anyContainer) 1 else 0) or (if (h.fieldMismatch) 2 else 0) or (if (h.nonProduction) 4 else 0)
    val record =
      BranchHopOut(
        f = loc(h.from), t = loc(h.to), k = str(h.kind)!!, s = site(h.site), r = str(h.rule),
        fm = h.fromMember?.let(memberIndex::get), tm = h.toMember?.let(memberIndex::get),
        e = h.edge, me = h.memberEdge, w = h.wrapDepth, c = h.cell, fc = h.fromCell, cc = h.containerChoices, fi = h.fanIn,
        ai = str(h.anyInstanceOf), p = str(h.property), fd = str(h.field), lm = str(h.landmark), x = flags,
      )
    return hops.getOrPut(record) { hops.size }
  }

  /** The locations hop records start and end at. */
  fun hopLocations(): Set<String> {
    val ids = locs.keys.toList()
    return hops.keys.flatMapTo(HashSet()) { listOf(ids[it.f], ids[it.t]) }
  }

  private fun hopsWithVars(vars: VariableTable?): List<BranchHopOut> {
    if (vars == null) return hops.keys.toList()
    val ids = locs.keys.toList()
    return hops.keys.map { it.copy(fv = vars.of(ids[it.f]), tv = vars.of(ids[it.t])) }
  }

  fun export(target: String, trees: List<BranchTreeOut>, links: List<CellLinkOut>, counts: Map<String, Int>, vars: VariableTable? = null) =
    BranchesExport(target = target, locs = locs.keys.toList(), strs = strs.keys.toList(), hops = hopsWithVars(vars), trees = trees, links = links, counts = counts)

  fun sinks(target: String, trees: List<BranchSinkTreeOut>, counts: Map<String, Int>, vars: VariableTable? = null) =
    BranchSinksExport(target = target, locs = locs.keys.toList(), strs = strs.keys.toList(), hops = hopsWithVars(vars), trees = trees, counts = counts)
}

/** One tree as the two files hold it: [sinks] is null when nothing was split out. */
class TreeOut(val main: BranchTreeOut, val sinks: BranchSinkTreeOut?)

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

  private val libraryCallsByInput: Map<String, List<String>> =
    facts.calls.filter { !it.targetInSource }.flatMap { c -> inputsOf(c.id).map { it to c.id } }.groupBy({ it.first }, { it.second })

  /**
   * A boundary result passed to a library call no model connects to that call's result, such as a
   * query object that `executeAsList()` or `watch()` runs, continues as that result, so the tree
   * starts where the data does.
   */
  private fun throughLibraryCalls(results: Set<String>): Set<String> {
    val out = sortedSetOf<String>().apply { addAll(results) }
    val queue = ArrayDeque(results.sorted())
    var guard = 0
    while (queue.isNotEmpty() && guard++ < LIBRARY_CHAIN_STEPS) {
      val location = queue.removeFirst()
      val reached = program.valueEdges[location].orEmpty().mapTo(HashSet()) { it.to }
      for (call in libraryCallsByInput[withoutContext(location)].orEmpty()) {
        val results = program.callResults(call)
        if (results.any { it in reached }) continue
        for (r in results) if (out.add(r)) queue += r
      }
    }
    return out
  }

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
      val results = throughLibraryCalls(program.callResults(b.call))
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

  /**
   * The tree against [tables]. With [sinkTables], sink terminals and the segments and points only
   * they use go to a second record numbered after the first; every point keeps a count of the sink
   * terminals past it. [withHops] false leaves the hop records of segments that are not clean out.
   */
  fun out(root: BranchRoot, tree: BranchTree, clean: Boolean, tables: BranchTables, sinkTables: BranchTables? = null, withHops: Boolean = true): TreeOut {
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
    fun isSink(t: BranchTree.Terminal) = sinkTables != null && t.path.key.kind == "sink"
    val mainSegments = BooleanArray(tree.segments.size)
    val mainPoints = BooleanArray(tree.points.size).also { it[0] = true }
    for (t in tree.terminals) {
      if (isSink(t)) continue
      mainPoints[t.point] = true
      for (s in t.segments) mainSegments[s] = true
    }
    for ((i, s) in tree.segments.withIndex()) if (mainSegments[i]) { mainPoints[s.a] = true; mainPoints[s.b] = true }
    val pointOrder = tree.points.indices.sortedBy { if (mainPoints[it]) 0 else 1 }
    val segmentOrder = tree.segments.indices.sortedBy { if (mainSegments[it]) 0 else 1 }
    val pointAt = IntArray(tree.points.size).also { a -> for ((n, o) in pointOrder.withIndex()) a[o] = n }
    val segmentAt = IntArray(tree.segments.size).also { a -> for ((n, o) in segmentOrder.withIndex()) a[o] = n }
    val sinksPast = IntArray(tree.points.size)
    for (t in tree.terminals) {
      if (!isSink(t)) continue
      val passed = HashSet<Int>().apply { add(t.point) }
      for (s in t.segments) { passed += tree.segments[s].a; passed += tree.segments[s].b }
      for (p in passed) sinksPast[p]++
    }
    fun tablesFor(main: Boolean) = if (main) tables else sinkTables!!
    val segments =
      segmentOrder.map { i ->
        val (segment, keep, out) = drafts[i]
        val withRecords = if (keep) out.copy(hops = segment.hops.map { tablesFor(mainSegments[i]).hop(records[it]!!, memberIndex) }) else out
        withRecords.copy(a = pointAt[segment.a], b = pointAt[segment.b])
      }
    val points =
      pointOrder.map { i ->
        val p = tree.points[i]
        val location = if (p.node == 0) rootLocation(root) else withoutContext(tree.nodes[p.node].state!!.location)
        BranchPointOut(memberOf(location), nodeOf(location), tablesFor(mainPoints[i]).loc(location), p.kind, sinksPast[i])
      }
    val terminals =
      tree.terminals.sortedBy { if (isSink(it)) 1 else 0 }.map { t ->
        isSink(t) to BranchTerminalOut(pointAt[t.point], t.path.key.kind, t.path.key.ref, t.path.cost.out(), minOf(t.path.equalCost, PATH_COUNT_CAP), t.path.clean, t.segments.map { segmentAt[it] })
      }
    val siblings =
      tree.siblings.map { s ->
        val t = tablesFor(mainPoints[s.point])
        mainPoints[s.point] to BranchSiblingOut(pointAt[s.point], s.kind, s.values.map { BranchSiblingValueOut(t.loc(it.location), memberOf(it.location), it.name) })
      }
    val mainPointCount = mainPoints.count { it }
    val mainSegmentCount = mainSegments.count { it }
    val rootLoc = rootLocation(root)
    val main =
      BranchTreeOut(
        root = BranchRootOut(tables.loc(rootLoc), memberOf(rootLoc), nodeOf(rootLoc), root.direction.label, root.kind, root.ref, root.label),
        options = BranchOptionsOut(tree.stops.toList(), clean = clean),
        truncated = tree.truncated,
        points = points.take(mainPointCount),
        segments = segments.take(mainSegmentCount),
        terminals = terminals.filter { !it.first }.map { it.second },
        siblings = siblings.filter { it.first }.map { it.second },
      )
    val sinkTerminals = terminals.filter { it.first }.map { it.second }
    val sinks =
      if (sinkTerminals.isEmpty()) null
      else BranchSinkTreeOut(-1, points.drop(mainPointCount), segments.drop(mainSegmentCount), sinkTerminals, siblings.filter { !it.first }.map { it.second })
    return TreeOut(main, sinks)
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
    private const val LIBRARY_CHAIN_STEPS = 50
  }
}

private fun PathCost.out() = CostOut(anyInstanceReads, stagedHops, conflation, derivedHops, length)
