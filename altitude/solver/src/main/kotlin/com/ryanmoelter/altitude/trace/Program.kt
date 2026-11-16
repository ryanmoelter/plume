package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.CellFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.facts.UNRESOLVED_TARGET
import com.ryanmoelter.altitude.solver.contextOf
import com.ryanmoelter.altitude.solver.expand
import com.ryanmoelter.altitude.solver.withDiFlows
import com.ryanmoelter.altitude.solver.withoutContext

private val CALLABLE_KINDS = setOf("fun", "ctor", "lambda", "getter", "setter")
private val CLASS_KINDS = setOf("class", "interface", "object", "enumEntry")
private val PSEUDO = Regex("""#<[^>]*>$""")
private val POSITIONAL = Regex("""^(.*):(\d+):(\d+)-(\d+):(\d+):(\w+)$""")
private val CALL_SELECTOR = Regex("""^(.+):(\d+):call\(([^)]+)\)$""")
private val VALUE_KINDS = setOf("prop", "param", "local")
private const val ELEMENT = "#<elem>"

/** From a container's contents to the container: the value now travels inside it. */
private const val HELD_BY = "heldBy"
private const val CALL_DEPTH = 6
private val FAKE_NAME = Regex("""Fake(?![a-z])""")
private const val PROJECTED_IN = "|"
private const val RETURN = "#<ret>"
private const val ONE_OF = "one of "
private const val ANY_FIELD = "*"
const val CONTAINER = "[]"
const val TRUNCATED = "…"

/**
 * Whether a value written at [write] is the one a read at [read] takes, both as [Program.writeAccess]
 * writes them: `match` when one is a prefix of the other, `mismatch` when they name different
 * fields, `unknown` when a container, an unnamed field or the depth limit decides it.
 */
fun accessCompat(write: List<String>, read: List<String>): String {
  for (i in 0 until minOf(write.size, read.size)) {
    val w = write[i]
    val r = read[i]
    if (w in OPAQUE || r in OPAQUE) return "unknown"
    if (w != r) return "mismatch"
  }
  return "match"
}

private val OPAQUE = setOf(ANY_FIELD, CONTAINER, TRUNCATED)
private val FRAME_PARTS = setOf("#<this>", "#<recv>", RETURN)
private val CONTEXT_MARK = Regex("""~\d+""")

/** The copy marks of an ID; empty for an original. */
private fun marksOf(id: String): String = CONTEXT_MARK.findAll(id).joinToString("") { it.value }

private val DERIVED_VALUE_KINDS = setOf("memberOf", "partOf", "contentOf", HELD_BY)
private val PACKAGE_PREFIX = Regex("""\b(?:[a-z_][A-Za-z0-9_]*\.)+(?=[A-Z])""")

/** A source position parsed from `relpath:line:col-line:col[:kind]`. */
data class Site(val path: String, val line: Int, val column: Int) : Comparable<Site> {
  override fun compareTo(other: Site): Int =
    compareValuesBy(this, other, { it.path }, { it.line }, { it.column })

  override fun toString(): String = "$path:$line"

  companion object {
    private val pattern = Regex("""^(.*):(\d+):(\d+)-\d+:\d+(?::\w+)?$""")

    fun of(location: String): Site? =
      pattern.matchEntire(location)?.destructured?.let { (path, line, column) ->
        Site(path, line.toInt(), column.toInt())
      }
  }
}

/** One step of the call graph: [caller] runs [callee] at [call]. */
class Hop(val edge: CallEdgeFact, val site: Site?, val otherSites: Int) {
  val caller: String
    get() = edge.caller

  val callee: String
    get() = edge.callee
}

/** The facts and what the solver derived from them, indexed for reading. */
class Program(val facts: Facts, val derived: Derived) {
  /**
   * The facts the solver ran on: wrapper functions are copied per call site. The `di` flows were
   * solver input rather than facts on disk, so only [Derived.flows] has them.
   */
  private val expansion = expand(withDiFlows(facts, derived.flows.filter { it.kind == "di" }))

  val decls: Map<String, DeclFact> =
    facts.decls.sortedBy { it.sym }.groupBy { it.sym }.mapValues { it.value.first() }
  val nodes: Map<String, NodeFact> = facts.nodes.associateBy { it.id }
  val calls: Map<String, CallFact> = facts.calls.associateBy { it.id }
  val fanOut: Map<String, Int> = derived.fanOuts.associate { it.call to it.count }
  val chaCandidates: Map<String, Int> =
    derived.callEdges.filter { it.via == "cha" }.groupingBy { it.call }.eachCount()
  val witnesses: Map<Pair<String, String>, List<FlowFact>> =
    derived.fnValues.sortedBy { it.witness.size }.groupBy { it.call to it.value }.mapValues {
      it.value.first().witness
    }

  /** One hop per caller and callee, at the first call site in the file. */
  val hops: Map<String, List<Hop>> =
    derived.callEdges
      .groupBy { it.caller }
      .mapValues { (_, edges) ->
        edges
          .groupBy { it.callee }
          .map { (_, sameCallee) ->
            val first = sameCallee.minWith(compareBy({ Site.of(it.call) }, { it.call }, { it.via }))
            Hop(first, Site.of(first.call), sameCallee.map { it.call }.distinct().size - 1)
          }
          .sortedWith(compareBy({ it.site }, { it.callee }))
      }

  private val edgesBetween: Map<Pair<String, String>, List<CallEdgeFact>> =
    derived.callEdges.groupBy { it.caller to it.callee }

  private val callsByArgumentNode: Map<String, Set<String>> =
    facts.args.groupBy({ it.node }, { it.call }).mapValues { it.value.toSet() }

  /**
   * [hop] at the call site that passes the function value [next] invokes, when [next] is a
   * `fnValue` hop and one of the sites does. The first site in the file may pass another value.
   */
  fun siteFor(hop: Hop, next: Hop?): Hop {
    if (next?.edge?.via != "fnValue") return hop
    val witness = witnesses[next.edge.call to next.callee].orEmpty()
    val passing =
      edgesBetween[hop.caller to hop.callee].orEmpty()
        .filter { edge -> witness.any { it.kind == "arg" && edge.call in callsByArgumentNode[it.from].orEmpty() } }
        .minWithOrNull(compareBy({ Site.of(it.call) }, { it.call }, { it.via }))
        ?: return hop
    return Hop(passing, Site.of(passing.call), hop.otherSites)
  }

  val cells: Map<String, CellFact> = derived.cells.associateBy { it.id }

  /** The cell made at [root], or at the call a copy of [root] copies. */
  fun cellAt(root: String): CellFact? = cells[original(root)]

  // A trace asks these of the same few thousand IDs on every hop.
  private val originals = HashMap<String, String>()
  private val contextKeys = HashMap<String, String>()

  private fun original(id: String): String = if ('~' in id) originals.getOrPut(id) { withoutContext(id) } else id

  private fun contextKey(id: String): String = if ('~' in id) contextKeys.getOrPut(id) { marksOf(id) } else ""

  private val contextFlows: List<FlowFact> =
    derived.contextFlows.ifEmpty { derived.flows.filter { it.kind != "di" } }

  /** Each location of the original facts with its copies. */
  private val copies: Map<String, List<String>> =
    expansion.facts.nodes.map { it.id }.groupBy(::withoutContext)

  private val cellsPerHolder: Map<String, Int> = derived.cells.mapNotNull { it.sym }.groupingBy { it }.eachCount()

  /** A holder that many cells pass through, such as a wrapper's local, names none of them. */
  fun cellName(cell: CellFact): String {
    val holder = cell.sym?.takeIf { cellsPerHolder[it] == 1 }
    return "${cell.mechanism} ${holder?.let(::qualifiedName) ?: display(cell.id)}"
  }

  /** Every flow edge, extracted and derived, by the location it leaves. */
  val valueEdges: Map<String, List<FlowFact>> =
    (expansion.facts.flows + contextFlows)
      .let { flows -> flows + holders(flows) }
      .groupBy { it.from }
      .mapValues { (_, edges) ->
        edges.distinct().sortedWith(compareBy({ it.to }, { it.kind }, { it.at }, { it.ruleId }))
      }

  /** The values that meet at a location: its distinct sources over edges that move a value. */
  val fanIn: Map<String, Int> =
    valueEdges.values
      .flatten()
      .filter { it.kind !in DERIVED_VALUE_KINDS }
      .groupBy { it.to }
      .mapValues { (_, edges) -> edges.map { it.from }.distinct().size }

  /** The containers that may be the one a port holds. */
  private val containerChoices: Map<String, Int> =
    valueEdges.mapValues { (_, edges) -> edges.count { it.kind == "contentOf" } }

  private fun holders(flows: List<FlowFact>): List<FlowFact> =
    flows
      .flatMap { listOf(it.from, it.to) }
      .filter { it.endsWith(ELEMENT) }
      .distinct()
      .mapNotNull { slot ->
        val root = slot.removeSuffix(ELEMENT)
        if (cellAt(root) != null || withoutContext(root) !in nodes) return@mapNotNull null
        FlowFact(slot, root, HELD_BY, withoutContext(root).substringBeforeLast(':'))
      }

  /** The call at which the edge steps from a container to its contents, or null when it does not. */
  fun projects(edge: FlowFact): String? =
    if (edge.kind == "contentOf" && edge.to.endsWith(ELEMENT)) edge.at + PROJECTED_IN + contextKey(edge.from) else null

  /** The call at which the edge writes into a container's contents, or null when it does not. */
  fun fills(edge: FlowFact): String? =
    if (edge.kind != "contentOf" && edge.kind != HELD_BY && edge.to.endsWith(ELEMENT)) edge.at else null

  /**
   * Whether the edge cannot follow a step into a container's contents at [projected]. Going back
   * up to the container would claim the value is in every container stored where that one was.
   * Leaving through the same call into another copy of it returns to a call the path never made:
   * that is an edge whose target the copy the path is in has too. A target only other code has,
   * such as a lambda the caller passed to a copied wrapper, is where the call really sends it.
   */
  private fun breaksProjection(edge: FlowFact, projected: String?): Boolean {
    if (projected == null) return false
    if (edge.kind == HELD_BY) return true
    val marks = projected.substringAfter(PROJECTED_IN)
    if (edge.at != projected.substringBefore(PROJECTED_IN) || contextKey(edge.to) == marks) return false
    val target = original(edge.to)
    return valueEdges[edge.from].orEmpty().any {
      it.kind == edge.kind && it.at == edge.at && contextKey(it.to) == marks && original(it.to) == target
    }
  }

  /** The member or top-level declaration a location belongs to. */
  private fun home(location: String): String? {
    val id = original(location.removeSuffix(ELEMENT)).substringBefore('#')
    var current = decls[nodes[id]?.enclosingDecl ?: id] ?: return null
    while (current.kind == "lambda" || current.kind == "local" || current.kind == "param") {
      current = decls[current.owner ?: break] ?: break
    }
    return current.sym
  }

  /**
   * Whether the edge reads a container's contents with nothing on the path to say which container:
   * the path stepped into the contents at another call ([projected]), or wrote them and now reads
   * them in another declaration than the one that made the container. Either way the read stands
   * for every container made there. A cell is exempt, being shared state by design.
   */
  fun readsAnyContainer(edge: FlowFact, projected: String?): Boolean {
    if (!edge.from.endsWith(ELEMENT) || edge.kind == HELD_BY) return false
    val root = edge.from.removeSuffix(ELEMENT)
    if (cellAt(root) != null) return false
    if (projected != null) return edge.at != projected.substringBefore(PROJECTED_IN)
    if (edge.to.endsWith(ELEMENT) || '~' in root) return false
    val made = home(root) ?: return false
    return made != home(edge.to)
  }

  fun hopCost(edge: FlowFact, projected: String?): PathCost {
    val choices = if (edge.kind == "contentOf") containerChoices[edge.from] ?: 1 else 1
    val derived = edge.kind == "memberOf" || edge.kind == "partOf" || edge.kind == HELD_BY || choices > 1
    val meeting = if (edge.kind == "contentOf") choices else fanIn[edge.to] ?: 1
    val anyInstance = isSharedByInstances(edge.from) || readsAnyContainer(edge, projected)
    return PathCost(
      anyInstanceReads = if (anyInstance) 1 else 0,
      stagedHops = if (isStaged(edge.to)) 1 else 0,
      conflation = bits(meeting),
      derivedHops = if (derived) 1 else 0,
      length = 1,
    )
  }

  private val stagingAnnotated: Set<String> =
    facts.annotations.filter { "Preview" in it.annFq.substringAfterLast('/') }.mapTo(HashSet()) { it.sym }

  private val testFiles: Set<String> =
    facts.files.filter { it.sourceSet?.contains("test", ignoreCase = true) == true }.mapTo(HashSet()) { it.path }

  private val staged = HashMap<String, Boolean>()

  /**
   * Whether the location is in code that production never runs: a test source set, a declaration
   * under a `@Preview` annotation, or a class named as a fake. A path through one is a path the
   * shipped program does not take, so it ranks below any path that stays in production code.
   */
  fun isStaged(location: String): Boolean {
    val id = original(location.removeSuffix(ELEMENT))
    val start = nodes[id]?.enclosingDecl ?: PSEUDO.find(id)?.let { id.removeSuffix(it.value) } ?: id
    return staged.getOrPut(start) {
      generateSequence(decls[start]) { decl -> decl.owner?.let { decls[it] } }.any { decl ->
        decl.sym in stagingAnnotated ||
          decl.file in testFiles ||
          (decl.kind in CLASS_KINDS && FAKE_NAME.containsMatchIn(decl.name))
      }
    }
  }

  /** Whether the location is a property of a class, which stands for that property of every instance. */
  fun isSharedByInstances(location: String): Boolean {
    if (!location.startsWith("prop:") || '~' in location) return false
    val owner = decls[location]?.owner?.let { decls[it] } ?: return false
    return owner.kind == "class" || owner.kind == "interface"
  }

  /** The calls a location is an argument or a receiver of. */
  private val callsEntered: Map<String, List<String>> =
    (expansion.facts.args.map { it.node to it.call } +
        expansion.facts.calls.flatMap { call -> (call.receiver + call.extReceiver).map { it to call.id } })
      .groupBy({ it.first }, { it.second })
      .mapValues { it.value.distinct().sorted() }

  private val callsByResult: Map<String, List<String>> =
    expansion.facts.calls.filter { it.result != null }.groupBy({ it.result!! }, { it.id })

  private val callers: Map<String, String> = expansion.facts.calls.associate { it.id to it.callerDecl }

  private val frames = HashMap<String, String>()

  /**
   * The function, lambda or initializer whose run holds the location, with the marks of its copy.
   * Null for a property or a container's contents, which outlive the run that wrote them.
   */
  private fun frame(location: String): String? =
    frames.getOrPut(location) { frameOf(location).orEmpty() }.ifEmpty { null }

  private fun frameOf(location: String): String? {
    if (location.endsWith(ELEMENT)) return null
    val id = original(location)
    val marks = contextKey(location)
    val pseudo = PSEUDO.find(id)?.value
    var current =
      when {
        pseudo != null -> if (pseudo in FRAME_PARTS) id.removeSuffix(pseudo) else return null
        else ->
          nodes[id]?.enclosingDecl
            ?: when (decls[id]?.kind) {
              null, "prop", "enumEntry" -> return null
              else -> id
            }
      }
    while (true) {
      val owner = decls[current] ?: break
      val inPlace = owner.kind == "lambda" && current + marks in lambdasRunWhereWritten
      if (owner.kind != "param" && owner.kind != "local" && !inPlace) break
      current = owner.owner ?: break
    }
    return current + marks
  }

  /**
   * Lambdas written as an argument whose function value goes nowhere else. Only the call it is
   * written in can run such a lambda, and what it captures is the variables of the run that
   * evaluated the call, so it counts as part of that run.
   */
  private val lambdasRunWhereWritten: Set<String> =
    expansion.facts.nodes
      .filter { it.kind == "lambdaExpr" && it.target != null && valueEdges[it.id].isNullOrEmpty() }
      .mapTo(HashSet()) { it.target!! }

  /** Whether the call entered at [entry], a call or the location passed to one of several, may be [call]. */
  private fun entered(entry: String, call: String): Boolean =
    if (entry.startsWith(ONE_OF)) call in callsEntered[entry.removePrefix(ONE_OF)].orEmpty() else entry == call

  /**
   * The calls a path is inside of after [edge], innermost last, or null when the edge returns to
   * a call the path did not come in through. Empty means unknown, and any return may follow.
   *
   * The list is kept only while it is known to describe the run the value is in: along an edge
   * inside one run, into a call, back out of the innermost one, into or out of a lambda a library
   * call runs, or to an override. Every other edge to another run forgets it, because a captured
   * variable, a property, a cell or a container's contents may be read by a run under any calls.
   * [projected] and [filled] say how the path came to a container's contents: those are known to
   * be in this run only when read at the call that stepped into them, or held by the container
   * the same call made.
   */
  fun callsAfter(calls: List<String>, edge: FlowFact, projected: String?, filled: String? = null): List<String>? {
    if (breaksProjection(edge, projected)) return null
    if (edge.from.endsWith(ELEMENT)) {
      if (cellAt(edge.from.removeSuffix(ELEMENT)) != null) return emptyList()
      val sameCall = if (edge.kind == HELD_BY) filled == edge.at else projected?.substringBefore(PROJECTED_IN) == edge.at
      return if (sameCall) calls else emptyList()
    }
    val origin = frame(edge.from) ?: return emptyList()
    val target = frame(edge.to)
    when (edge.kind) {
      "arg", "receiver", "invokeArg" -> {
        // A bound reference's receiver enters no call here; the function runs when it is invoked.
        val entries = callsEntered[edge.from]
        if (target == null || entries == null) return emptyList()
        // An implicit `this` passed from inside a lambda leaves the run that `this` belongs to.
        val known = if (entries.all { callers[it]?.let(::frame) == origin }) calls else emptyList()
        return (known + (entries.singleOrNull() ?: (ONE_OF + edge.from))).takeLast(CALL_DEPTH)
      }
      "return", "invokeReturn" -> {
        val returned = callsByResult[edge.to].takeIf { edge.from.endsWith(RETURN) }
        if (returned != null) {
          val innermost = calls.lastOrNull() ?: return calls
          return if (returned.any { entered(innermost, it) }) calls.dropLast(1) else null
        }
      }
      "override", "summary" -> if (target != null) return calls
    }
    return if (target == origin || edge.to.endsWith(ELEMENT)) calls else emptyList()
  }

  private val argsByNode: Map<String, List<ArgFact>> = facts.args.groupBy { it.node }.mapValues { (_, a) -> a.sortedBy { it.call } }

  /**
   * The parameter a `partOf` edge passes its value as, or the property a `memberOf` edge reads.
   * Null when the facts do not name one.
   */
  fun fieldOf(edge: FlowFact): String? =
    when (edge.kind) {
      "partOf" -> {
        val args = argsByNode[original(edge.from)]
        val to = original(edge.to)
        (args?.firstOrNull { calls[it.call]?.result == to } ?: args?.firstOrNull())?.param?.substringAfterLast('#')
      }
      "memberOf" -> propertyName(original(edge.to))
      else -> null
    }

  private val partsInto: Map<String, List<FlowFact>> by lazy {
    valueEdges.values.flatten().filter { it.kind == "partOf" }.groupBy { original(it.to) }.mapValues { (_, e) -> e.distinctBy { original(it.from) } }
  }

  private val membersFrom: Map<String, List<FlowFact>> by lazy {
    valueEdges.values.flatten().filter { it.kind == "memberOf" }.groupBy { original(it.from) }.mapValues { (_, e) -> e.distinctBy { original(it.to) } }
  }

  /** The `partOf` edges building values into an object, one per value, ignoring context. */
  fun partsOf(location: String): List<FlowFact> =
    partsInto[original(location)].orEmpty().map { FlowFact(original(it.from), original(it.to), it.kind, it.at, it.ruleId) }.sortedBy { it.from }

  /** The `memberOf` edges reading properties out of an object, one per read, ignoring context. */
  fun membersOf(location: String): List<FlowFact> =
    membersFrom[original(location)].orEmpty().map { FlowFact(original(it.from), original(it.to), it.kind, it.at, it.ruleId) }.sortedBy { it.to }

  /** The property a property reference names. */
  fun propertyName(location: String): String? {
    val target = nodes[location]?.target ?: return null
    return decls[target]?.name ?: target.substringBefore("#<").substringBefore('(').substringAfterLast('/').substringAfterLast('.')
  }

  /**
   * For each hop of a value path, the field the value was built into when the hop is a `memberOf`
   * that reads another field of that object, else null. The innermost `partOf` the path is still
   * inside names the field; a container the path entered since hides it. Ranking ignores this.
   */
  fun fieldMismatches(hops: List<FlowFact>): List<String?> {
    // Innermost last; null stands for a container.
    val enclosing = ArrayList<String?>()
    return hops.map { hop ->
      when {
        hop.kind == "partOf" -> enclosing += fieldOf(hop) ?: ANY_FIELD
        hop.kind == HELD_BY -> enclosing += null
        hop.kind == "contentOf" && hop.to.endsWith(ELEMENT) -> if (enclosing.isNotEmpty() && enclosing.last() == null) enclosing.removeLast()
        hop.kind == "memberOf" && enclosing.isNotEmpty() && enclosing.last() != null -> {
          val built = enclosing.removeLast()!!
          val read = fieldOf(hop)
          return@map built.takeIf { it != ANY_FIELD && read != null && it != read }
        }
      }
      null
    }
  }

  /**
   * The fields the path's value sits in where the path ends, outermost first: a cell write's place
   * in the cell's contents. A container is `[]`, an unnamed field `*`, and `…` ends a path deeper
   * than [depth].
   */
  fun writeAccess(hops: List<FlowFact>, depth: Int): List<String> {
    val enclosing = ArrayList<String>()
    for (hop in hops) {
      when {
        hop.kind == "partOf" -> enclosing += fieldOf(hop) ?: ANY_FIELD
        hop.kind == HELD_BY -> enclosing += CONTAINER
        hop.kind == "contentOf" && hop.to.endsWith(ELEMENT) -> if (enclosing.lastOrNull() == CONTAINER) enclosing.removeLast()
        hop.kind == "memberOf" && enclosing.isNotEmpty() && enclosing.last() != CONTAINER -> enclosing.removeLast()
      }
    }
    val outward = enclosing.asReversed()
    return if (outward.size > depth) outward.take(depth) + TRUNCATED else outward.toList()
  }

  /** The projections a path takes from its start's value before building anything, as [writeAccess] writes them. */
  fun readAccess(hops: List<FlowFact>, depth: Int): List<String> {
    val read = ArrayList<String>()
    var built = 0
    for (hop in hops) {
      when {
        hop.kind == "partOf" || hop.kind == HELD_BY -> built++
        hop.kind == "memberOf" -> if (built > 0) built-- else read += fieldOf(hop) ?: ANY_FIELD
        hop.kind == "contentOf" && hop.to.endsWith(ELEMENT) -> if (built > 0) built-- else read += CONTAINER
      }
      if (read.size > depth) return read.take(depth) + TRUNCATED
    }
    return read
  }

  fun hopNotes(edge: FlowFact, projected: String?): List<String> = buildList {
    if (readsAnyContainer(edge, projected)) add("any container made there")
    when (edge.kind) {
      HELD_BY -> add("the container holding it")
      "memberOf" -> add("projection")
      "partOf" -> add("construction")
      "contentOf" -> {
        val choices = containerChoices[edge.from] ?: 1
        add(if (choices > 1) "container, 1 of $choices" else "container")
      }
      else -> fanIn[edge.to]?.takeIf { it > 1 }?.let { add("fan-in $it") }
    }
    if (isSharedByInstances(edge.from)) add("any instance's ${decls[edge.from]?.name}")
  }

  /** What a hop contributes to a trace's skeleton: a cell it enters, or an object it builds. */
  fun landmark(edge: FlowFact): String? {
    if (edge.to.endsWith(ELEMENT)) {
      val cell = cellAt(edge.to.removeSuffix(ELEMENT)) ?: return null
      return cellName(cell).substringAfter(' ').let { if (cell.sym != null && cellsPerHolder[cell.sym] == 1) it.substringAfterLast(' ') else cellName(cell) }
    }
    if (edge.kind == "partOf") {
      val target = nodes[original(edge.to)]?.target ?: return null
      // A `copy` call's result names its call, whose generated target has no declaration.
      val copied = calls[target]?.target ?: return "new " + qualifiedName(target)
      return "copy of " + copied.substringBefore('(').substringAfterLast('/').substringBeforeLast('.')
    }
    return null
  }

  private fun bits(count: Int): Int = if (count <= 1) 0 else 32 - Integer.numberOfLeadingZeros(count - 1)

  /** A summary's `at` is its call's position, which a copy of the call shares with the original. */
  private val summariesBySite: Map<String, List<FlowFact>> =
    contextFlows.filter { it.ruleId != null }.groupBy { it.at }

  /** Calls into code outside the analysed sources, by the declaration that makes them. */
  val boundaryCalls: Map<String, List<CallFact>> =
    facts.calls
      .filter { !it.targetInSource && it.target != UNRESOLVED_TARGET && it.dispatch != "invokeFnValue" }
      .filter { !it.target.endsWith("#<get>") && !it.target.endsWith("#<set>") }
      .groupBy { it.callerDecl }
      .mapValues { it.value.sortedWith(compareBy({ Site.of(it.id) }, { it.id })) }

  fun isCallable(sym: String): Boolean = decls[sym]?.kind in CALLABLE_KINDS

  /** `Owner.name` without parameters; what a selector matches. */
  fun qualifiedName(sym: String): String {
    if (contextOf(sym) != null) return qualifiedName(withoutContext(sym))
    val decl = decls[sym] ?: return libraryName(sym)
    val owner = decl.owner?.let { decls[it] }
    val ownerIsClass = owner?.kind in CLASS_KINDS
    return when (decl.kind) {
      in CLASS_KINDS ->
        when {
          "anonymous" in decl.modifiers -> "object@${shortSite(decl)}"
          ownerIsClass -> "${qualifiedName(owner!!.sym)}.${decl.name}"
          else -> decl.name
        }
      "lambda" ->
        "lambda@${decl.file.orEmpty().substringAfterLast('/')}:${decl.span.orEmpty().substringBefore('-')}"
      "local" -> "${decl.name}@${shortSite(decl)}"
      "param" -> "${qualifiedName(decl.owner!!)}#${decl.name}"
      "getter",
      "setter" -> "${qualifiedName(decl.owner!!)}.${decl.name}"
      else ->
        when {
          ownerIsClass -> "${qualifiedName(owner!!.sym)}.${decl.name}"
          owner != null && owner.kind in CALLABLE_KINDS -> "${decl.name}@${shortSite(decl)}"
          else -> decl.name
        }
    }
  }

  /** A name a reader can find in the source: `Owner.name(ParamType)`, `lambda@File.kt:12`. */
  fun display(sym: String): String {
    if (contextOf(sym) != null) return "${display(withoutContext(sym))} {copy for ${copySites(sym).joinToString(" in ")}}"
    val decl = decls[sym]
    if (decl == null) {
      if (sym.endsWith(ELEMENT)) {
        val root = sym.removeSuffix(ELEMENT)
        val cell = cellAt(root) ?: return "element of ${display(root)}"
        return "cell ${cellName(cell)}"
      }
      PSEUDO.find(sym)?.let { return display(sym.removeSuffix(it.value)) + it.value }
      val node = nodes[sym]
      val positional = POSITIONAL.matchEntire(sym)
      if (positional != null) {
        val (path, line, column, _, _, kind) = positional.destructured
        val label = "$kind@${path.substringAfterLast('/')}:$line:$column"
        val target = node?.target?.takeIf { node.kind.endsWith("Ref") }
        return if (target != null) "$label (${display(target)})" else label
      }
      return libraryName(sym) + " [library]"
    }
    return when (decl.kind) {
      "fun",
      "ctor" -> qualifiedName(sym) + "(" + parameterTypes(sym) + ")"
      else -> qualifiedName(sym)
    }
  }

  /**
   * The calls a copy was made for, innermost first. A copy's call can itself lie in a copy, and a
   * copy of a copy carries both marks.
   */
  private fun copySites(id: String): List<String> =
    CONTEXT_MARK.findAll(id).toList().asReversed().flatMap { mark ->
      val call = expansion.contexts[mark.value.drop(1).toInt()]
      val site = Site.of(withoutContext(call))
      listOf("${site?.path?.substringAfterLast('/')}:${site?.line}") + copySites(call)
    }

  private val parameters: Map<String, List<DeclFact>> =
    facts.decls.filter { it.kind == "param" && it.owner != null }.groupBy { it.owner!! }

  private val constructors: Map<String, List<String>> =
    facts.decls.filter { it.kind == "ctor" && it.owner != null }.groupBy({ it.owner!! }, { it.sym })

  fun constructorsOf(sym: String): List<String> = constructors[sym].orEmpty().sorted()

  private fun parameterTypes(sym: String): String =
    parameters[sym]
      .orEmpty()
      .sortedBy { it.index }
      .joinToString(", ") { it.type.orEmpty().replace(PACKAGE_PREFIX, "") }
      .let { if (it.length > 60) it.take(57) + "..." else it }

  private fun shortSite(decl: DeclFact): String =
    "${decl.file.orEmpty().substringAfterLast('/')}:${decl.span.orEmpty().substringBefore(':')}"

  private fun libraryName(sym: String): String =
    sym.substringAfter(':').substringBefore('(').substringBefore('@')

  /** Declarations a selector names: an exact symbol ID, or a unique `Owner.member` suffix. */
  fun select(selector: String, includeLibrary: Boolean = false): Selection {
    if (selector in decls) return Selection(selector, listOf(selector), emptyList())
    val matches =
      decls.values
        .filter { it.kind in CALLABLE_KINDS || it.kind in CLASS_KINDS }
        .filter { matches(qualifiedName(it.sym), selector) || matches(display(it.sym), selector) }
        .map { it.sym }
        .sorted()
    if (matches.isNotEmpty() || !includeLibrary) return Selection(selector, matches, emptyList())
    val library =
      boundaryCalls.values
        .asSequence()
        .flatten()
        .map { it.target }
        .distinct()
        .filter { it == selector || matches(libraryName(it).replace('/', '.'), selector) }
        .sorted()
        .toList()
    return Selection(selector, emptyList(), library)
  }

  /**
   * The locations a value selector names: `File.kt:LINE:call(name)`, `cell(Owner.name)` for what a
   * cell holds, a location ID, or a property, parameter or local by `Owner.name`. A call starts a
   * trace at its result and ends one at any of its ports, or at what a model says it writes.
   */
  fun selectValue(selector: String, goal: Boolean): ValueSelection {
    val callSelector = CALL_SELECTOR.matchEntire(selector)
    if (callSelector != null) {
      val (path, line, name) = callSelector.destructured
      val matching =
        expansion.facts.calls
          .filter { call ->
            val site = Site.of(call.id) ?: return@filter false
            site.line == line.toInt() &&
              (site.path == path || site.path.endsWith("/$path")) &&
              calleeName(call.target) == name
          }
          .sortedBy { it.id }
      val original = matching.map { withoutContext(it.id) }.distinct()
      if (original.size != 1) return ValueSelection(selector, emptySet(), original)
      val locations = LinkedHashSet<String>()
      for (call in matching) {
        val arguments = expansion.facts.args.filter { it.call == call.id }.map { it.node }
        if (goal) {
          locations += arguments + call.receiver + call.extReceiver + listOfNotNull(call.result)
          summariesBySite[withoutContext(call.id).substringBeforeLast(':')].orEmpty().filter { it.kind == "summary" }.mapTo(locations) { it.to }
        } else {
          locations += listOfNotNull(call.result).ifEmpty { arguments }
        }
      }
      val call = matching.first()
      return ValueSelection(
        "${Site.of(original.single())} ${display(withoutContext(call.target))}",
        locations,
        emptyList(),
      )
    }
    if (selector.startsWith("cell(") && selector.endsWith(")")) {
      val name = selector.removePrefix("cell(").removeSuffix(")")
      val matching =
        derived.cells.filter { cell -> cell.sym?.let { it == name || matches(qualifiedName(it), name) } == true }
      val slots = matching.flatMap { copies[it.id] ?: listOf(it.id) }.map { it + ELEMENT }.toSet()
      val label = matching.map { display(it.id + ELEMENT) }.distinct().joinToString().ifEmpty { selector }
      return ValueSelection(label, slots, emptyList())
    }
    if (selector in decls || selector in nodes || selector in valueEdges) {
      return ValueSelection(display(selector), setOf(selector), emptyList())
    }
    val named =
      decls.values
        .filter { it.kind in VALUE_KINDS && matches(qualifiedName(it.sym), selector) }
        .map { it.sym }
        .sorted()
    val one = named.singleOrNull() ?: return ValueSelection(selector, emptySet(), named)
    return ValueSelection(display(one), setOf(one), emptyList())
  }

  /** The slots of a cell's contents: the cell's own and those of its copies. */
  fun cellSlots(cellId: String): Set<String> = (copies[cellId] ?: listOf(cellId)).mapTo(sortedSetOf()) { it + ELEMENT }

  private val callCopies: Map<String, List<CallFact>> by lazy { expansion.facts.calls.groupBy { withoutContext(it.id) } }
  private val expandedArgs: Map<String, List<String>> by lazy { expansion.facts.args.groupBy({ it.call }, { it.node }) }

  /** The results of a call and of its copies. */
  fun callResults(callId: String): Set<String> = callCopies[callId].orEmpty().mapNotNullTo(sortedSetOf()) { it.result }

  /** The arguments and receivers of a call and of its copies. */
  fun callInputs(callId: String): Set<String> =
    callCopies[callId].orEmpty().flatMapTo(sortedSetOf()) { expandedArgs[it.id].orEmpty() + it.receiver + it.extReceiver }

  private fun calleeName(target: String): String =
    decls[target]?.name
      ?: libraryName(target.replace(PSEUDO, "")).substringAfterLast('/').substringAfterLast('.')

  private fun matches(name: String, selector: String): Boolean =
    name == selector || name.endsWith(".$selector")
}

/** [candidates] lists what an ambiguous selector matched. */
class ValueSelection(val label: String, val locations: Set<String>, val candidates: List<String>)

class Selection(val selector: String, val decls: List<String>, val library: List<String>) {
  val isUnique: Boolean
    get() = decls.size + library.size == 1
}

/** What a value path costs, most important first. */
data class PathCost(
  /** Reads of a class property or of a container made elsewhere, with no object to say whose. */
  val anyInstanceReads: Int,
  /** Hops in previews, fakes and tests. */
  val stagedHops: Int,
  val conflation: Int,
  val derivedHops: Int,
  val length: Int,
) : Comparable<PathCost> {
  operator fun plus(other: PathCost): PathCost =
    PathCost(
      anyInstanceReads + other.anyInstanceReads,
      stagedHops + other.stagedHops,
      conflation + other.conflation,
      derivedHops + other.derivedHops,
      length + other.length,
    )

  override fun compareTo(other: PathCost): Int =
    compareValuesBy(
      this,
      other,
      { it.anyInstanceReads },
      { it.stagedHops },
      { it.conflation },
      { it.derivedHops },
      { it.length },
    )

  fun describe(): String =
    "$anyInstanceReads any-instance reads, $stagedHops hops outside production code, " +
      "conflation $conflation, $derivedHops derived hops, $length hops"

  companion object {
    val ZERO = PathCost(0, 0, 0, 0, 0)
  }
}
