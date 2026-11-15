package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.solver.withoutContext

enum class Direction(val label: String) {
  /** From the root to where its value goes. */
  FORWARD("forward"),

  /** From where the root's value comes from to the root. */
  BACKWARD("backward"),
}

/**
 * A place a branch tree ends: `boundary`, `cellWrite`, `cellRead`, `ui`, `entry` or `sink`. [ref]
 * is an index whose list depends on [kind]; the classifier that made the key knows which.
 */
data class TerminalKey(val kind: String, val ref: Int) : Comparable<TerminalKey> {
  override fun compareTo(other: TerminalKey): Int = compareValuesBy(this, other, { TERMINAL_KINDS.indexOf(it.kind) }, { it.ref })
}

val TERMINAL_KINDS = listOf("boundary", "cellWrite", "cellRead", "ui", "entry", "sink")

/** The terminals of one tree, by the location the tree reaches them at. */
fun interface Terminals {
  fun classify(location: String): TerminalKey?
}

class BranchOptions(
  /** Terminal kinds a path may not pass through; a terminal behind one is left out. */
  val stops: Set<String>,
  /** Search steps a forward tree's search may take. */
  val forwardSteps: Int = 50_000_000,
  /** States the backward reachability graph may hold. */
  val backwardStates: Int = 3_000_000,
  /** Steps of each backward terminal's own search, as `trace --value` allows. */
  val legSteps: Int = TraceOptions().searchBudget,
)

/** The best path between the root and one terminal, in data-flow order. */
class BranchPath(val key: TerminalKey, val states: List<ValueState>, val hops: List<FlowFact>, val cost: PathCost, val equalCost: Long) {
  val clean: Boolean
    get() = cost.anyInstanceReads == 0 && cost.stagedHops == 0
}

class BranchSearchResult(val paths: List<BranchPath>, val truncated: Boolean)

/**
 * Finds the best path between a root and every terminal, under the ranking of `trace --value`. A
 * forward search runs `trace`'s own search from the root and keeps going, so the first state it
 * settles at a terminal ends the path `trace` would print to that terminal. A path that passes a
 * terminal of a [BranchOptions.stops] kind is left out, rather than the search stopping there,
 * because stopping would change which of two equal-cost paths the search reaches first.
 *
 * Backward, there is no reverse search yet. The stand-in builds the state graph forward from every
 * terminal that reaches the root ignoring calls, walks it back from the root's states, and runs a
 * forward search from each terminal that reaches the root. It is exact, and slow.
 */
class BranchSearch(private val program: Program) {
  private val predecessors: Map<String, List<String>> by lazy {
    val out = HashMap<String, MutableList<String>>()
    for (edges in program.valueEdges.values) for (edge in edges) out.getOrPut(edge.to) { ArrayList() } += edge.from
    out
  }

  fun search(direction: Direction, root: Set<String>, terminals: Terminals, options: BranchOptions): BranchSearchResult =
    when (direction) {
      Direction.FORWARD -> forward(root, terminals, options)
      Direction.BACKWARD -> backward(root, terminals, options)
    }

  private fun forward(root: Set<String>, terminals: Terminals, options: BranchOptions): BranchSearchResult {
    val run = ValueSearch(program, options.forwardSteps).run(root, ValueGoal.Everything)
    val seen = root.mapNotNullTo(HashSet()) { terminals.classify(it) }
    val paths = ArrayList<BranchPath>()
    for (state in run.settled) {
      if (state.location in root) continue
      val key = terminals.classify(state.location) ?: continue
      if (!seen.add(key)) continue
      val states = run.statesTo(state)
      if (passesStop(states, root, key, terminals, options)) continue
      paths += BranchPath(key, states, run.hopsTo(state), run.best.getValue(state), run.paths.getValue(state))
    }
    return BranchSearchResult(paths.sortedBy { it.key }, run.exhausted)
  }

  private fun passesStop(states: List<ValueState>, start: Set<String>, own: TerminalKey, terminals: Terminals, options: BranchOptions): Boolean =
    states.subList(1, states.size - 1).any { s ->
      s.location !in start && terminals.classify(s.location)?.let { it != own && it.kind in options.stops } == true
    }

  private fun backward(root: Set<String>, terminals: Terminals, options: BranchOptions): BranchSearchResult {
    val reaching = HashSet(root)
    val queue = ArrayDeque(root.sorted())
    while (queue.isNotEmpty()) for (p in predecessors[queue.removeFirst()].orEmpty()) if (reaching.add(p)) queue += p
    val own = root.mapNotNullTo(HashSet()) { terminals.classify(it) }
    val starts = sortedMapOf<TerminalKey, MutableSet<String>>()
    for (location in reaching) {
      if (location in root) continue
      val key = terminals.classify(location)?.takeIf { it !in own } ?: continue
      starts.getOrPut(key) { sortedSetOf() } += location
    }
    val (reached, truncated) = reachesRoot(starts.values.flatten().filter { it in reaching }.toSortedSet(), reaching, root, options.backwardStates)
    val paths = ArrayList<BranchPath>()
    var legTruncated = false
    for ((key, locations) in starts) {
      if (locations.none { ValueState(it, emptyList()) in reached }) continue
      val allow: (ValueState) -> Boolean = if (truncated) { s -> s.location in reaching } else { s -> s in reached }
      val run = ValueSearch(program, options.legSteps).run(locations, ValueGoal.Locations(root), allow = allow)
      if (run.exhausted) legTruncated = true
      val end = run.end ?: continue
      val states = run.statesTo(end)
      if (passesStop(states, locations, key, terminals, options)) continue
      paths += BranchPath(key, states, run.hopsTo(end), run.best.getValue(end), run.paths.getValue(end))
    }
    return BranchSearchResult(paths, truncated || legTruncated)
  }

  /** The states, of those reachable from [starts] within [reaching], from which a state at [root] is reachable. */
  private fun reachesRoot(starts: Set<String>, reaching: Set<String>, root: Set<String>, cap: Int): Pair<Set<ValueState>, Boolean> {
    val index = HashMap<ValueState, Int>()
    val states = ArrayList<ValueState>()
    val successors = ArrayList<IntList>()
    fun id(state: ValueState): Int = index.getOrPut(state) { states += state; successors += IntList(); states.size - 1 }
    val queue = ArrayDeque<Int>()
    for (location in starts) queue += id(ValueState(location, emptyList()))
    var truncated = false
    while (queue.isNotEmpty()) {
      val i = queue.removeFirst()
      val state = states[i]
      if (state.location in root) continue
      for (edge in program.valueEdges[state.location].orEmpty()) {
        if (edge.to !in reaching) continue
        val calls = program.callsAfter(state.calls, edge, state.projected, state.filled) ?: continue
        val before = states.size
        val j = id(ValueState(edge.to, calls, program.projects(edge), program.fills(edge)))
        successors[i].add(j)
        if (states.size > before) {
          if (states.size > cap) {
            truncated = true
            queue.clear()
            break
          }
          queue += j
        }
      }
    }
    val predecessorsOf = Array(states.size) { IntList() }
    for (i in states.indices) for (k in 0 until successors[i].size) predecessorsOf[successors[i][k]].add(i)
    val reach = BooleanArray(states.size)
    val walk = ArrayDeque<Int>()
    for (i in states.indices) if (states[i].location in root) { reach[i] = true; walk += i }
    while (walk.isNotEmpty()) {
      val j = walk.removeFirst()
      for (k in 0 until predecessorsOf[j].size) {
        val i = predecessorsOf[j][k]
        if (!reach[i]) { reach[i] = true; walk += i }
      }
    }
    return states.indices.filter { reach[it] }.mapTo(HashSet()) { states[it] } to truncated
  }
}

private class IntList {
  private var items = IntArray(4)
  var size = 0
    private set

  fun add(x: Int) {
    if (size == items.size) items = items.copyOf(size * 2)
    items[size++] = x
  }

  operator fun get(i: Int) = items[i]
}

/**
 * The best paths of a [BranchSearchResult] merged into one tree: paths share a node while they
 * share a prefix from the root, a hop and the state it reaches. Node 0 is the root.
 */
class BranchTree(
  val direction: Direction,
  val root: Set<String>,
  val stops: Set<String>,
  val truncated: Boolean,
  val paths: List<BranchPath>,
  program: Program,
) {
  /**
   * [step] joins the node to its parent. [state] is the node's own state: where the hop lands going
   * forward, where it leaves from going backward. [upstream] is the hop's starting state.
   */
  class Node(val parent: Int, val step: FlowFact?, val state: ValueState?, val upstream: ValueState?) {
    val children = ArrayList<Int>()
    var fieldMismatch: String? = null
  }

  class Point(val node: Int, val kind: String)

  /** [hops] are node indices, one per hop, in data-flow order; [a] and [b] are point indices in that order too. */
  class Segment(val a: Int, val b: Int, val hops: List<Int>)

  class Terminal(val path: BranchPath, val node: Int, val point: Int, val segments: List<Int>)

  class Sibling(val point: Int, val kind: String, val values: List<SiblingValue>)

  class SiblingValue(val location: String, val name: String?)

  val nodes = ArrayList<Node>().apply { add(Node(-1, null, null, null)) }
  val points: List<Point>
  val segments: List<Segment>
  val terminals: List<Terminal>
  val siblings: List<Sibling>

  init {
    val index = HashMap<Pair<Int, Pair<FlowFact, ValueState>>, Int>()
    val ends = ArrayList<Int>()
    for (path in paths) {
      val mismatches = program.fieldMismatches(path.hops)
      val steps = path.hops.indices.let { if (direction == Direction.FORWARD) it.toList() else it.reversed() }
      var current = 0
      for (i in steps) {
        val upstream = path.states[i]
        val downstream = path.states[i + 1]
        val own = if (direction == Direction.FORWARD) downstream else upstream
        val edge = path.hops[i]
        current = index.getOrPut(current to (edge to own)) {
          nodes += Node(current, edge, own, upstream)
          nodes[current].children += nodes.size - 1
          nodes.size - 1
        }
        mismatches[i]?.let { if (nodes[current].fieldMismatch == null) nodes[current].fieldMismatch = it }
      }
      ends += current
    }
    val flags = Array(nodes.size) { sortedSetOf<String>() }
    flags[0] += "root"
    for (end in ends) flags[end] += "terminal"
    for ((i, node) in nodes.withIndex()) if (node.children.size >= 2) flags[i] += "branch"
    val multiplicity = nodes.drop(1).groupingBy { withoutContext(it.state!!.location) }.eachCount()
    fun shared(i: Int) = i != 0 && (multiplicity[withoutContext(nodes[i].state!!.location)] ?: 0) > 1
    for (i in 1 until nodes.size) {
      val node = nodes[i]
      if (shared(i) && !shared(node.parent)) flags[i] += "merge"
      val downstream = if (direction == Direction.FORWARD) i else node.parent
      val upstream = if (direction == Direction.FORWARD) node.parent else i
      if (node.step!!.kind == "partOf") flags[downstream] += "join"
      if (node.step.kind == "memberOf") flags[upstream] += "split"
    }
    val pointOf = IntArray(nodes.size) { -1 }
    val pointList = ArrayList<Point>()
    for (i in nodes.indices) {
      val kind = POINT_KINDS.firstOrNull { it in flags[i] } ?: continue
      pointOf[i] = pointList.size
      pointList += Point(i, kind)
    }
    points = pointList
    val segmentInto = IntArray(nodes.size) { -1 }
    val segmentList = ArrayList<Segment>()
    for (point in pointList) {
      if (point.node == 0) continue
      val walk = ArrayList<Int>()
      var current = point.node
      while (pointOf[current] < 0 || current == point.node) {
        walk += current
        current = nodes[current].parent
      }
      val near = pointOf[current]
      segmentInto[point.node] = segmentList.size
      segmentList +=
        if (direction == Direction.FORWARD) Segment(near, pointOf[point.node], walk.asReversed().toList())
        else Segment(pointOf[point.node], near, walk)
    }
    segments = segmentList
    terminals =
      paths.mapIndexed { i, path ->
        val chain = ArrayList<Int>()
        var current = ends[i]
        while (current != 0) {
          if (pointOf[current] >= 0) chain += segmentInto[current]
          current = nodes[current].parent
        }
        Terminal(path, ends[i], pointOf[ends[i]], if (direction == Direction.FORWARD) chain.asReversed() else chain)
      }
    siblings = siblingsOf(program, flags, pointOf)
  }

  /** The other arguments built into each object a path joins, and the other properties read where one splits. */
  private fun siblingsOf(program: Program, flags: Array<out Set<String>>, pointOf: IntArray): List<Sibling> {
    val joins = sortedMapOf<Int, MutableSet<String>>()
    val splits = sortedMapOf<Int, MutableSet<String>>()
    val objects = HashMap<Int, String>()
    for (i in 1 until nodes.size) {
      val node = nodes[i]
      val edge = node.step!!
      val downstream = if (direction == Direction.FORWARD) i else node.parent
      val upstream = if (direction == Direction.FORWARD) node.parent else i
      if (edge.kind == "partOf") {
        joins.getOrPut(downstream) { HashSet() } += withoutContext(edge.from)
        objects[downstream] = withoutContext(edge.to)
      }
      if (edge.kind == "memberOf") {
        splits.getOrPut(upstream) { HashSet() } += withoutContext(edge.to)
        objects[upstream] = withoutContext(edge.from)
      }
    }
    val out = ArrayList<Sibling>()
    for ((node, onTree) in joins) {
      if ("join" !in flags[node] || pointOf[node] < 0) continue
      val values = program.partsOf(objects.getValue(node)).filter { it.from !in onTree }.map { SiblingValue(it.from, program.fieldOf(it)) }
      if (values.isNotEmpty()) out += Sibling(pointOf[node], "join", values)
    }
    for ((node, onTree) in splits) {
      if ("split" !in flags[node] || pointOf[node] < 0) continue
      val values = program.membersOf(objects.getValue(node)).filter { it.to !in onTree }.map { SiblingValue(it.to, program.fieldOf(it)) }
      if (values.isNotEmpty()) out += Sibling(pointOf[node], "split", values)
    }
    return out.sortedWith(compareBy({ it.point }, { it.kind }))
  }

  /** The node indices of a terminal's path, in data-flow order. */
  fun hopNodes(terminal: Terminal): List<Int> = terminal.segments.flatMap { segments[it].hops }

  companion object {
    /** A node that is several kinds of point takes the first. */
    val POINT_KINDS = listOf("root", "terminal", "branch", "merge", "join", "split")
  }
}
