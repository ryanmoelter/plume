package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.rules.Rules
import com.ryanmoelter.altitude.solver.withoutContext
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.Site
import java.util.TreeMap
import java.util.TreeSet

val LAYERS = listOf("external", "data", "presentation", "ui")
const val EVIDENCE_SITES = 3
const val MEMBER_EVIDENCE_SITES = 2
const val INFRA_FEATURES = 3
const val LOOP_HOPS = 40

/** Loop owner roles, deepest first; ties in the label go to the deeper level. */
val LOOP_LEVELS = listOf("repository", "mediator", "host", "ui", "other")

/** What one derived edge between two nodes collected: its distinct evidence and where it happens. */
private class EdgeAgg {
  val evidence = TreeSet<String>()
  val sites = TreeSet<Site>()
  val detail = TreeMap<String, Int>()
}

/** Builds the export of one target from its facts, derived relations and rule rows. */
class Exporter(
  private val target: String,
  private val facts: Facts,
  private val derived: Derived,
  private val rules: Rules,
  private val meta: MetaFact,
) {
  val units = Units(facts)
  private val containment = Containment(units)
  private val graph = CallGraph(facts, derived, rules)
  private val nodeIds: List<String> = units.nodes.keys.toList()
  private val composable: Set<String> = facts.annotations.filter { it.annFq == COMPOSABLE }.mapTo(HashSet()) { it.sym }
  private val eventLambdas: Set<String> =
    derived.callEdges.filter { it.via == "invoke" && it.role?.startsWith("event") == true }.mapTo(HashSet()) { it.callee }
  private val contentLambdas: Set<String> =
    derived.callEdges.filter { it.via == "invoke" && it.role?.startsWith("content") == true }.mapTo(HashSet()) { it.callee }
  private val callsById = facts.calls.associateBy { it.id }
  private val files: List<String> = facts.files.map { it.path }.sorted()
  private val fileIndex: Map<String, Int> = files.withIndex().associate { it.value to it.index }

  private fun site(s: Site): String = "${fileIndex[s.path] ?: s.path}:${s.line}"
  private val classByDotted: Map<String, String> =
    units.decls.values.filter { it.kind in CLASS_KINDS }.associate { it.sym.substringAfter(':').replace('/', '.') to it.sym }

  // ---- declaration context -------------------------------------------------------------------

  private val contexts = HashMap<String, String>()

  /** `ui` for composable code, `uiEvent` for an event callback a composable passes, else `code`. */
  fun context(decl: String): String =
    contexts.getOrPut(decl) {
      var current = units.decls[decl]
      var guard = 0
      while (current != null && guard++ < 200) {
        if (current.sym in eventLambdas) return@getOrPut "uiEvent"
        if (current.sym in composable || current.sym in contentLambdas) return@getOrPut "ui"
        if (current.kind in CLASS_KINDS) break
        current = current.owner?.let { units.decls[it] }
      }
      "code"
    }

  private fun accessDecl(id: String): String? = callsById[id]?.callerDecl ?: units.nodesById[id]?.enclosingDecl

  private fun typeNode(type: String?): String? {
    if (type == null) return null
    val bare = type.substringBefore('<').removeSuffix("?").trim()
    return classByDotted[bare]?.let(units::ofDecl)
  }

  private fun firstTypeArgument(type: String?): String? {
    if (type == null || '<' !in type) return null
    val inner = type.substringAfter('<').substringBeforeLast('>')
    var depth = 0
    val end = inner.indexOfFirst { c -> if (c == '<') depth++ else if (c == '>') depth--; c == ',' && depth == 0 }
    return if (end < 0) inner else inner.substring(0, end)
  }

  // ---- cells ---------------------------------------------------------------------------------

  private val writesByCell = derived.cellWrites.groupBy { it.cell }
  private val readsByCell = derived.cellReads.groupBy { it.cell }
  private val cellFacts = derived.cells.sortedBy { it.id }
  private val cellIndex: Map<String, Int> = cellFacts.withIndex().associate { it.value.id to it.index }
  val members = Members(units, composable, cellFacts)
  private val cellMembers: List<String?> = cellFacts.map { members.ofLocation(it.sym ?: it.id) }

  val cells: List<CellOut> =
    cellFacts.map { cell ->
      val holder = cell.sym?.let { units.decls[it] }
      val owner = cell.sym?.let(units::of) ?: units.of(cell.id)
      val scope = if (holder?.kind == "prop") "property" else "local"
      fun accesses(rows: List<com.ryanmoelter.altitude.facts.CellAccessFact>) =
        rows.filter { it.cell == cell.id && it.op != "initial" }
          .mapNotNull { row -> accessDecl(row.node)?.let { d -> units.ofDecl(d)?.let { Triple(it, row.op, context(d)) } } }
          .groupingBy { it }.eachCount()
          .map { (k, n) -> CellAccessOut(k.first, k.second, n, k.third) }
          .sortedWith(compareBy({ it.node }, { it.op }, { it.context }))
      CellOut(
        id = cell.id,
        holder = cell.sym,
        mechanism = cell.mechanism,
        owner = owner,
        scope = scope,
        elementType = typeNode(firstTypeArgument(units.nodesById[cell.id]?.type)),
        writers = accesses(writesByCell[cell.id].orEmpty()),
        readers = accesses(readsByCell[cell.id].orEmpty()),
      )
    }


  // ---- edges ---------------------------------------------------------------------------------

  private val edgeAggs = TreeMap<Triple<String, String, String>, EdgeAgg>(compareBy({ it.first }, { it.second }, { it.third }))
  private val memberAggs = TreeMap<Triple<String, String, String>, EdgeAgg>(compareBy({ it.first }, { it.second }, { it.third }))

  private fun EdgeAgg.add(evidence: String, detail: String?) {
    if (this.evidence.add(evidence)) {
      siteOf(evidence, units)?.let { sites += it }
      detail?.let { this.detail.merge(it, 1, Int::plus) }
    }
  }

  /** Records one fact between two nodes, and between the members it runs from and to. */
  private fun edge(from: String?, to: String?, kind: String, evidence: String, detail: String?, fromMember: String?, toMember: String?) {
    if (from == null || to == null) return
    if (from !in units.nodes || to !in units.nodes) return
    if (fromMember != null && toMember != null && fromMember != toMember) memberAggs.getOrPut(Triple(fromMember, toMember, kind)) { EdgeAgg() }.add(evidence, detail)
    if (from != to) edgeAggs.getOrPut(Triple(from, to, kind)) { EdgeAgg() }.add(evidence, detail)
  }

  private fun declEdge(from: String?, to: String?, kind: String, evidence: String, detail: String?) =
    edge(from?.let(units::ofDecl), to?.let(units::ofDecl), kind, evidence, detail, from?.let(members::ofDecl), to?.let(members::ofDecl))

  private fun locationEdge(from: String, to: String, kind: String, evidence: String, detail: String?) =
    edge(units.of(from), units.of(to), kind, evidence, detail, members.ofLocation(from), members.ofLocation(to))

  init {
    for (e in derived.callEdges) {
      when (e.via) {
        "di" -> declEdge(e.caller, e.callee, "di", e.call, "accessor")
        "cell" -> {}
        else -> declEdge(e.caller, e.callee, "call", e.call, e.via)
      }
    }
    // Every di edge points from the injection site to the provider, the way a call does.
    for (f in derived.flows) if (f.kind == "di") locationEdge(f.to, f.from, "di", f.at, "injection")
    for (f in valueFlows(facts, derived)) locationEdge(f.from, f.to, "value", f.at, f.kind)
    for ((i, cell) in cells.withIndex()) {
      for (w in writesByCell[cell.id].orEmpty().filter { it.op != "initial" }) {
        val decl = accessDecl(w.node)
        edge(decl?.let(units::ofDecl), cell.owner, "cellWrite", w.node, w.op, decl?.let(members::ofDecl), cellMembers[i])
      }
      for (r in readsByCell[cell.id].orEmpty()) {
        val decl = accessDecl(r.node)
        edge(cell.owner, decl?.let(units::ofDecl), "cellRead", r.node, r.op, cellMembers[i], decl?.let(members::ofDecl))
      }
    }
    for (n in rules.navigations) declEdge(n.from, n.to, "navigation", n.call, n.op)
  }

  // ---- placement -----------------------------------------------------------------------------

  private val declsOf: Map<String, List<com.ryanmoelter.altitude.facts.DeclFact>> = units.declsByNode

  private fun dist(node: String, distance: Map<String, Int>): Dist? {
    val decls = declsOf[node].orEmpty()
    val all = decls.mapNotNull { distance[it.sym] }
    if (all.isEmpty()) return null
    val named = decls.filter { it.kind in CALLABLE_KINDS }.mapNotNull { distance[it.sym] }.sorted()
    val median = if (named.isEmpty()) all.min() else named[(named.size - 1) / 2]
    return Dist(all.min(), median, named.size)
  }

  private val boundaryNodes: Map<String, Map<String, Int>> =
    rules.boundaries.mapNotNull { b -> units.ofDecl(b.caller)?.let { it to b.kind } }
      .groupBy({ it.first }, { it.second }).mapValues { (_, kinds) -> kinds.groupingBy { it }.eachCount().toSortedMap() }

  /** Nodes that hold the library-facing end of a boundary: a target in the sources, or an operation class. */
  private val boundaryTargetNodes: Set<String> =
    (rules.boundaries.mapNotNull { units.ofDecl(it.target) } +
      rules.boundaries.mapNotNull { b -> b.operation?.let { classByDotted[it] }?.let(units::ofDecl) }).toSet()

  private val entryNodes: List<String?> = graph.entries.map { e -> e.attrs["screen"]?.let(units::ofDecl) ?: units.ofDecl(e.sym) }

  private val entryKindsByNode: Map<String, List<String>> =
    graph.entries.indices.mapNotNull { i -> entryNodes[i]?.let { it to graph.entries[i].kind } }
      .groupBy({ it.first }, { it.second }).mapValues { it.value.distinct().sorted() }

  private val ownedCells = cells.withIndex().filter { it.value.owner != null }.groupBy({ it.value.owner!! }, { it.index })
  private val writtenCells = cells.withIndex().flatMap { (i, c) -> c.writers.map { it.node to i } }.groupBy({ it.first }, { it.second })
  private val readCells = cells.withIndex().flatMap { (i, c) -> c.readers.map { it.node to i } }.groupBy({ it.first }, { it.second })

  private fun uiEvidence(node: String): UiEvidence {
    val decls = declsOf[node].orEmpty()
    val funs = decls.filter { it.kind == "fun" }
    return UiEvidence(
      composableFuns = funs.count { it.sym in composable },
      funs = funs.size,
      uiReads = cells.sumOf { c -> c.readers.filter { it.node == node && it.context == "ui" }.sumOf { it.count } },
      eventLambdas = decls.count { it.sym in eventLambdas },
    )
  }

  private fun isDataType(node: String): Boolean {
    val info = units.nodes.getValue(node)
    if (info.kind == "file") return false
    if (ownedCells[node].orEmpty().isNotEmpty()) return false
    if (info.modifiers.any { it in setOf("data", "enum", "value", "sealed", "annotation") }) return true
    val decls = declsOf[node].orEmpty().filter { "implicit" !in it.modifiers }
    return decls.none { it.kind == "fun" && units.ofDecl(it.sym) == node } && decls.any { it.kind == "prop" }
  }

  private val placements: Map<String, Placement> =
    nodeIds.associateWith { node ->
      Placement(
        down = graph.boundaryDistance.mapNotNull { (kind, d) -> dist(node, d)?.let { kind to it } }.toMap().toSortedMap(),
        up = graph.entryDistance.mapNotNull { (kind, d) -> dist(node, d)?.let { kind to it } }.toMap().toSortedMap(),
        boundaryCalls = boundaryNodes[node].orEmpty(),
        entryKinds = entryKindsByNode[node].orEmpty(),
        cells = CellRefs(ownedCells[node].orEmpty(), writtenCells[node].orEmpty().distinct().sorted(), readCells[node].orEmpty().distinct().sorted()),
        ui = uiEvidence(node),
        dataType = isDataType(node),
      )
    }

  /** Node pairs joined by a call that names its callee, as opposed to a callback. */
  private val directCalls: Set<Pair<String, String>> =
    derived.callEdges.filter { it.via in DIRECT_VIAS }
      .mapNotNull { e -> units.ofDecl(e.caller)?.let { a -> units.ofDecl(e.callee)?.let { b -> (a to b).takeIf { a != b } } } }.toSet()

  private val callers: Map<String, Set<String>> =
    directCalls.groupBy({ it.second }, { it.first }).mapValues { it.value.toSortedSet() }

  /** The layer and why, or null when nothing places the node. */
  private val layers: Map<String, Pair<Int?, String>> = deriveLayers()

  private fun deriveLayers(): Map<String, Pair<Int?, String>> {
    val out = TreeMap<String, Pair<Int?, String>>()
    val inherit = ArrayList<String>()
    for (node in nodeIds) {
      val p = placements.getValue(node)
      val ui = p.ui
      val dataDown = p.down.filterKeys { it !in TELEMETRY_KINDS }.values.minOfOrNull { it.min }
      val up = p.up.values.minOfOrNull { it.min }
      out[node] =
        when {
          node in boundaryTargetNodes -> 0 to "boundaryTarget"
          p.entryKinds.isEmpty() && ui.composableFuns > 0 && ui.composableFuns * 2 >= ui.funs -> 3 to "composable"
          p.entryKinds.isNotEmpty() -> 2 to "entryHost"
          p.boundaryCalls.keys.any { it !in TELEMETRY_KINDS } -> 1 to "boundaryCaller"
          p.dataType -> { inherit += node; null to "" }
          dataDown != null && up != null -> if (dataDown <= up) 1 to "closerToBoundary:$dataDown<=$up" else 2 to "closerToEntry:$dataDown>$up"
          dataDown != null -> 1 to "reachesBoundary"
          else -> { inherit += node; null to "" }
        }
    }
    var changed = true
    while (changed) {
      changed = false
      for (node in inherit) {
        // An external adapter builds the models it returns; that does not make them external.
        val from = callers[node].orEmpty().mapNotNull { c -> out[c]?.first }
        val best = from.filter { it > 0 }.minOrNull() ?: from.minOrNull() ?: continue
        if (out.getValue(node).first != best) {
          out[node] = best to "inheritsFromCallers"
          changed = true
        }
      }
    }
    for (node in inherit) if (out.getValue(node).first == null) out[node] = null to (if (placements.getValue(node).dataType) "unusedDataType" else "unplaced")
    return out
  }

  fun layerOf(node: String): Int? = layers[node]?.first

  // ---- features ------------------------------------------------------------------------------

  private val featureOf = containment.featureOf
  private val entryFeatures: List<String?> = entryNodes.map { it?.let(featureOf::get) }

  private val reachedBy: Map<String, List<Int>> =
    graph.reached.withIndex()
      .flatMap { (i, decls) -> decls.mapNotNull(units::ofDecl).distinct().map { it to i } }
      .groupBy({ it.first }, { it.second }).mapValues { it.value.distinct().sorted() }

  /**
   * The nodes that depend on each node: its direct callers, the readers of its cells and the
   * injection sites it provides for. Value edges stay out: an argument flows from caller to callee,
   * against the dependency.
   */
  private val dependents: Map<String, Set<String>> =
    (directCalls.map { it.second to it.first } +
      edgeAggs.keys.filter { it.third == "cellRead" }.map { it.first to it.second } +
      edgeAggs.keys.filter { it.third == "di" }.map { it.second to it.first })
      .groupBy({ it.first }, { it.second }).mapValues { it.value.toSortedSet() }

  private val featuresWithEntries: Set<String> = entryFeatures.filterNotNull().toSet()

  private fun reach(node: String): Reach {
    val entries = reachedBy[node].orEmpty()
    return Reach(
      entries,
      sortedMapOf(
        "feature" to entries.mapNotNull { entryFeatures[it] }.distinct().sorted(),
        "module" to entries.mapNotNull { entryNodes[it]?.let { n -> units.nodes[n]?.module } }.distinct().sorted(),
      ).filterValues { it.isNotEmpty() },
    )
  }

  private fun fanIn(node: String): FanIn {
    val from = dependents[node].orEmpty()
    return FanIn(
      from.size,
      from.mapNotNull(featureOf::get).filter { it != featureOf[node] }.distinct().sorted(),
      from.mapNotNull(::layerOf).distinct().sorted(),
    )
  }

  private fun infrastructure(node: String, fanIn: FanIn, reach: Reach): Infrastructure {
    val entryFeats = reach.byContainer["feature"].orEmpty()
    val union = (fanIn.features + entryFeats).toSet()
    val total = containment.features.size.coerceAtLeast(1)
    val why = ArrayList<String>()
    if (fanIn.features.size >= INFRA_FEATURES) why += "usedByFeatures:${fanIn.features.size}"
    if (entryFeats.size >= INFRA_FEATURES) why += "reachedFromFeatures:${entryFeats.size}"
    if (fanIn.layers.size >= 3) why += "usedFromLayers:${fanIn.layers.joinToString("+")}"
    return Infrastructure(round3(union.size.toDouble() / total), why.isNotEmpty(), why)
  }

  private fun misplaced(node: String, reach: Reach): Misplaced? {
    val own = featureOf[node] ?: return null
    val from = reach.byContainer["feature"].orEmpty().singleOrNull() ?: return null
    if (from == own || own !in featuresWithEntries) return null
    return Misplaced(own, from)
  }

  // ---- roles ---------------------------------------------------------------------------------

  private val graphNodes: Map<String, Int> =
    rules.bindings.mapNotNull { b -> classByDotted[b.graph]?.let(units::ofDecl) }.groupingBy { it }.eachCount()
  private val providerNodes: Map<String, Int> =
    rules.bindings.mapNotNull { b -> units.ofDecl(b.provider)?.takeIf { b.kind != "constructor" && b.kind != "inject" } }.groupingBy { it }.eachCount()
  private val navigatesFrom: Map<String, Int> = rules.navigations.mapNotNull { units.ofDecl(it.from) }.groupingBy { it }.eachCount()

  private fun roles(node: String): List<Role> {
    val p = placements.getValue(node)
    val out = ArrayList<Role>()
    fun role(name: String, vararg evidence: Pair<String, Any?>) {
      out += Role(name, jsonObject(evidence.filter { it.second != null }.toMap()))
    }
    val property = p.cells.owned.filter { cells[it].scope == "property" }
    val local = p.cells.owned.filter { cells[it].scope == "local" }
    val foreignWrites = p.cells.writes.filter { cells[it].owner != node && cells[it].owner?.let(::staged) != true }
    val uiReads = p.ui.uiReads
    if (p.entryKinds.isNotEmpty()) role("entryPoint", "kinds" to p.entryKinds)
    if (p.entryKinds.isNotEmpty() && p.ui.composableFuns > 0) role("screenHost", "composableFuns" to p.ui.composableFuns, "propertyCells" to property.size)
    if (property.isNotEmpty()) {
      val readers = property.flatMap { cells[it].readers.map { r -> r.node } }.filter { it != node }.distinct()
      role("stateHolder", "propertyCells" to property.size, "mechanisms" to property.map { cells[it].mechanism }.distinct().sorted(), "readByNodes" to readers.size)
    }
    if (local.isNotEmpty() && p.ui.composableFuns > 0) role("uiState", "localCells" to local.size)
    if (foreignWrites.isNotEmpty()) role("stateWriter", "cellsOfOtherNodes" to foreignWrites.size, "owners" to foreignWrites.mapNotNull { cells[it].owner }.distinct().sorted())
    if (uiReads > 0) role("uiReader", "uiReads" to uiReads)
    if (p.entryKinds.isEmpty() && p.ui.composableFuns > 0 && p.ui.composableFuns * 2 >= p.ui.funs) role("uiComponent", "composableFuns" to p.ui.composableFuns, "funs" to p.ui.funs)
    val dataDown = p.down.filterKeys { it !in TELEMETRY_KINDS }
    if (p.boundaryCalls.isNotEmpty()) role("boundaryAdapter", "calls" to p.boundaryCalls)
    if (node in boundaryTargetNodes) role("externalAdapter", "generated" to units.nodes.getValue(node).generated)
    val presentationCallers = callers[node].orEmpty().filter { layerOf(it) == 2 }
    if (p.entryKinds.isEmpty() && p.ui.composableFuns == 0 && dataDown.isNotEmpty() && presentationCallers.isNotEmpty() && !p.dataType && node !in boundaryTargetNodes) {
      role(
        "mediator",
        "presentationCallers" to presentationCallers.size,
        "propertyCells" to property.size,
        "boundaryHops" to dataDown.values.minOf { it.min },
        "callsBoundaryDirectly" to p.boundaryCalls.keys.any { it !in TELEMETRY_KINDS },
      )
    }
    if (node in graphNodes || node in providerNodes) role("diGraph", "graphBindings" to graphNodes[node], "providedBindings" to providerNodes[node])
    navigatesFrom[node]?.let { role("navigator", "navigations" to it) }
    if (p.dataType) role("pureData", "modifiers" to units.nodes.getValue(node).modifiers)
    return out
  }

  // ---- bundles -------------------------------------------------------------------------------

  private fun wraps(): List<WrapOut> {
    val agg = TreeMap<Pair<String, String>, EdgeAgg>(compareBy({ it.first }, { it.second }))
    for (f in facts.flows) {
      if (f.kind != "partOf") continue
      val inner = typeNode(units.nodesById[f.from]?.type ?: units.decls[f.from]?.type) ?: continue
      val outer = typeNode(units.nodesById[f.to]?.type) ?: continue
      if (inner == outer) continue
      val a = agg.getOrPut(inner to outer) { EdgeAgg() }
      if (a.evidence.add(f.at)) siteOf(f.at, units)?.let { a.sites += it }
    }
    return agg.map { (k, a) -> WrapOut(k.first, k.second, a.evidence.size, a.sites.take(EVIDENCE_SITES).map(::site)) }
  }

  private fun argGroups(): List<ArgGroupOut> {
    val args = facts.args.groupBy { it.call }
    val out = ArrayList<ArgGroupOut>()
    for (call in facts.calls.sortedBy { it.id }) {
      if (!call.targetInSource) continue
      val from = units.ofDecl(call.callerDecl) ?: continue
      val to = units.ofDecl(call.target) ?: continue
      if (from == to) continue
      val values = args[call.id].orEmpty().filter { it.form != "receiver" }.sortedWith(compareBy({ it.index }, { it.node }))
      if (values.map { it.index }.distinct().size < 2) continue
      val byParam = values.groupBy { it.index }.toSortedMap().values.map { it.first() }
      out += ArgGroupOut(
        call = Site.of(call.id)?.let(::site) ?: call.id,
        from = from,
        to = to,
        callee = call.target,
        params = byParam.map { it.param.substringAfterLast('#') },
        types = byParam.map { typeNode(units.nodesById[it.node]?.type) },
      )
    }
    return out
  }

  // ---- patterns ------------------------------------------------------------------------------

  private val flowAdjacency: Map<String, List<String>> by lazy {
    (facts.flows + derived.flows).filter { it.kind != "di" }.groupBy({ it.from }, { it.to }).mapValues { (_, v) -> v.distinct().sorted() }
  }

  /** The cells whose element a cell's element reaches over flow edges, within a step budget. */
  private val feeds = HashMap<Int, Set<Int>>()

  private fun feeds(cell: Int): Set<Int> =
    feeds.getOrPut(cell) {
      val start = cells[cell].id + ELEMENT
      val seen = HashSet<String>().apply { add(start) }
      val queue = ArrayDeque(listOf(start))
      var steps = 0
      while (queue.isNotEmpty() && steps++ < 50_000) {
        for (n in flowAdjacency[queue.removeFirst()].orEmpty()) if (seen.add(n)) queue += n
      }
      seen.mapNotNull { it.removeSuffix(ELEMENT).takeIf { s -> it.endsWith(ELEMENT) }?.let(cellIndex::get) }.toSet()
    }

  private fun ownerRole(node: String?, roles: Map<String, List<Role>>): String {
    val names = node?.let { roles[it] }.orEmpty().map { it.role }
    return when {
      "entryPoint" in names -> "host"
      "mediator" in names && placements.getValue(node!!).boundaryCalls.keys.any { it !in TELEMETRY_KINDS } -> "repository"
      "mediator" in names -> "mediator"
      "uiComponent" in names -> "ui"
      else -> "other"
    }
  }

  private fun loops(roles: Map<String, List<Role>>): List<LoopOut> {
    val writesByDecl = HashMap<String, MutableSet<Int>>()
    for (w in derived.cellWrites) {
      if (w.op == "initial") continue
      val decl = accessDecl(w.node) ?: continue
      if (units.ofDecl(decl)?.let(::staged) == true) continue
      val i = cellIndex[w.cell] ?: continue
      if (cells[i].owner?.let(::staged) == true) continue
      writesByDecl.getOrPut(decl) { sortedSetOf() } += i
    }
    val out = ArrayList<LoopOut>()
    // A local cell counts: composable code usually reads a property cell through a collectAsState local.
    for ((i, cell) in cells.withIndex()) {
      for (reader in cell.readers.filter { it.context == "ui" && !staged(it.node) }.map { it.node }.distinct()) {
        val starts = declsOf[reader].orEmpty().filter { it.sym in eventLambdas }.associate { it.sym to 0 }
        if (starts.isEmpty()) continue
        val reached = graph.bfs(starts, graph.forward, LOOP_HOPS)
        val hit =
          reached.entries.sortedWith(compareBy({ it.value }, { it.key })).firstNotNullOfOrNull { (decl, hops) ->
            writesByDecl[decl]?.firstOrNull { w -> w == i || i in feeds(w) }?.let { Triple(decl, hops, it) }
          } ?: continue
        val written = cells[hit.third]
        out += LoopOut(i, hit.third, written.owner, ownerRole(written.owner, roles), reader, units.ofDecl(hit.first) ?: "?", hit.second)
      }
    }
    return out
  }

  private fun patternVector(scope: String, nodes: List<String>, roles: Map<String, List<Role>>, loops: List<LoopOut>): PatternVector {
    val inScope = nodes.toSet()
    val c = TreeMap<String, Int>()
    fun inc(key: String, n: Int = 1) {
      if (n != 0) c.merge(key, n, Int::plus)
    }
    fun has(node: String, role: String) = roles[node].orEmpty().any { it.role == role }
    val hosts = nodes.filter { has(it, "entryPoint") }
    inc("nodes", nodes.size)
    inc("entryHosts", hosts.size)
    inc("hostsWithUi", hosts.count { placements.getValue(it).ui.composableFuns > 0 })
    inc("hostsOwningState", hosts.count { h -> placements.getValue(h).cells.owned.any { cells[it].scope == "property" } })
    val holders = nodes.filter { has(it, "stateHolder") && !has(it, "entryPoint") }
    val hostNodes = entryNodes.filterNotNull().toSet()
    for (h in holders) {
      val screens = reachedBy[h].orEmpty().mapNotNull { entryNodes[it] }.filter { it in hostNodes }.distinct()
      inc(if (screens.size == 1) "holders.perScreen" else if (screens.size > 1) "holders.shared" else "holders.unreached")
    }
    inc("mediators", nodes.count { has(it, "mediator") })
    for (cell in cells) {
      if (cell.owner !in inScope) continue
      inc("cells.${cell.scope}")
      if (cell.scope == "property") inc("cells.property.${ownerRole(cell.owner, roles)}")
    }
    for (cell in cells) {
      val ownerRole = if (cell.scope == "local") "local" else ownerRole(cell.owner, roles)
      for (w in cell.writers) {
        if (w.node !in inScope) continue
        inc("writes.${w.context}", w.count)
        if (w.context != "code") inc("writes.${w.context}.to.$ownerRole", w.count)
        if (cell.owner != w.node) inc("writes.crossNode", w.count)
      }
      for (r in cell.readers) {
        if (r.node !in inScope || r.context != "ui") continue
        inc("reads.ui.of.$ownerRole", r.count)
      }
    }
    for (e in graph.edges) {
      if (e.caller !in eventLambdas || e.via == "invoke") continue
      val from = units.ofDecl(e.caller) ?: continue
      if (from !in inScope) continue
      val callee = units.decls[e.callee]
      if (callee == null || callee.sym in composable) continue
      inc(if (units.ofDecl(e.callee) == from) "eventCalls.sameNode" else "eventCalls.otherNode")
    }
    inc("singleStateHosts", hosts.count { h ->
      val owned = placements.getValue(h).cells.owned.filter { cells[it].scope == "property" && !cells[it].mechanism.startsWith("Compose") }
      owned.size == 1 && cells[owned.single()].elementType != null
    })
    inc("reducers", nodes.sumOf { n -> declsOf[n].orEmpty().count(::isReducer) })
    val scoped = loops.filter { it.reader in inScope }
    inc("loops", scoped.size)
    for (l in scoped) inc("loops.${l.ownerRole}")
    for ((_, ls) in scoped.groupBy { it.reader }) inc("loopReaders.deepest.${ls.minBy { LOOP_LEVELS.indexOf(it.ownerRole) }.ownerRole}")
    val (label, because) = label(c)
    return PatternVector(scope, c, label, because)
  }

  /** `(S, E) -> S` where E is a sealed type of the sources: the signature of a reducer. */
  private fun isReducer(decl: com.ryanmoelter.altitude.facts.DeclFact): Boolean {
    if (decl.kind != "fun") return false
    val params = units.decls.values.filter { it.owner == decl.sym && it.kind == "param" }.sortedBy { it.index }
    if (params.size != 2 || params[0].type == null || params[0].type != decl.type) return false
    val event = typeNode(params[1].type)?.let { units.nodes[it] } ?: return false
    return "sealed" in event.modifiers
  }

  private fun label(c: Map<String, Int>): Pair<String?, List<String>> {
    fun n(k: String) = c[k] ?: 0
    val because = ArrayList<String>()
    val parts = ArrayList<String>()
    val perScreen = n("holders.perScreen")
    if (n("hostsOwningState") > 0 && n("hostsWithUi") > 0 && n("eventCalls.sameNode") > 0 && perScreen < n("hostsOwningState")) {
      parts += "screen-hosted MVP"
      because += listOf("hostsOwningState=${n("hostsOwningState")}", "hostsWithUi=${n("hostsWithUi")}", "eventCalls.sameNode=${n("eventCalls.sameNode")}", "holders.perScreen=$perScreen")
    } else if (perScreen > 0 && perScreen >= n("hostsOwningState")) {
      parts += "MVVM"
      because += listOf("holders.perScreen=$perScreen", "hostsOwningState=${n("hostsOwningState")}")
    }
    if (n("reducers") > 0 && n("singleStateHosts") * 2 >= n("hostsOwningState").coerceAtLeast(1)) {
      parts += "MVI"
      because += listOf("reducers=${n("reducers")}", "singleStateHosts=${n("singleStateHosts")}")
    }
    val level = LOOP_LEVELS.maxByOrNull { n("loopReaders.deepest.$it") }?.takeIf { n("loopReaders.deepest.$it") > 0 }
    if (level != null) {
      parts += "$level-level unidirectional loop"
      because += listOf("loops=${n("loops")}", "loopReaders.deepest.$level=${n("loopReaders.deepest.$level")}")
    }
    if (parts.isEmpty() && n("cells.property") == 0 && n("entryHosts") > 0) {
      parts += "stateless request handling"
      because += listOf("cells.property=0", "entryHosts=${n("entryHosts")}")
    }
    return (if (parts.isEmpty()) null else parts.joinToString(" with a ")) to because
  }

  // ---- assembly ------------------------------------------------------------------------------

  fun build(golden: List<GoldenQuery> = emptyList()): AltitudeExport = buildAll(golden).first

  /** The export and its members file. */
  fun buildAll(golden: List<GoldenQuery> = emptyList()): Pair<AltitudeExport, MembersExport> {
    val roles = nodeIds.associateWith(::roles)
    val edges =
      edgeAggs.map { (k, a) ->
        EdgeOut(
          from = k.first,
          to = k.second,
          kind = k.third,
          count = a.evidence.size,
          sites = a.sites.take(EVIDENCE_SITES).map(::site),
          detail = a.detail,
          crossesLayer = layerOf(k.first) != layerOf(k.second),
          crossesFeature = featureOf[k.first] != featureOf[k.second],
        )
      }
    val edgeIndex = edgeAggs.keys.withIndex().associate { it.value to it.index }
    val memberEdgeIndex = memberAggs.keys.withIndex().associate { it.value to it.index }
    val traces = TraceRunner(program, units, members, cellIndex).let { runner -> golden.map { runner.run(it, edgeIndex, memberEdgeIndex) } }
    val membersOut = membersExport(edgeIndex)
    val nodes =
      nodeIds.map { id ->
        val info = units.nodes.getValue(id)
        val reach = reach(id)
        val fanIn = fanIn(id)
        val (layer, why) = layers.getValue(id)
        NodeOut(
          id = id,
          kind = info.kind,
          name = info.name,
          container = "file:${info.file}",
          feature = featureOf.getValue(id),
          file = info.file,
          line = info.line,
          generated = info.generated,
          staged = staged(id),
          nonProduction = nodeNonProduction(id),
          modifiers = info.modifiers,
          size = Size(info.loc, units.declCounts[id] ?: 0),
          layer = layer,
          layerWhy = why,
          placement = placements.getValue(id),
          reach = reach,
          fanIn = fanIn,
          infrastructure = infrastructure(id, fanIn, reach),
          misplaced = misplaced(id, reach),
          roles = roles.getValue(id),
        )
      }
    val loops = loops(roles)
    val byFeature = nodeIds.groupBy { featureOf.getValue(it) }
    val containerSizes = containerSizes()
    val entries =
      graph.entries.mapIndexed { i, e ->
        EntryOut(e.kind, e.sym, e.attrs, entryNodes[i], entryFeatures[i], e.file, e.line)
      }
    val export = AltitudeExport(
      meta =
        ExportMeta(
          target = target,
          gitSha = meta.gitSha,
          gitDirty = meta.gitDirty,
          factsSchemaVersion = meta.schemaVersion,
          params = sortedMapOf("megamorphic" to MEGAMORPHIC, "evidenceSites" to EVIDENCE_SITES, "infraFeatures" to INFRA_FEATURES, "loopHops" to LOOP_HOPS),
          layers = LAYERS,
          membersFile = MEMBERS_FILE,
          counts =
            sortedMapOf(
              "nodes" to nodes.size,
              "edges" to edges.size,
              "containers" to containment.containers.size,
              "features" to containment.features.size,
              "cells" to cells.size,
              "entrypoints" to entries.size,
              "boundaries" to rules.boundaries.size,
              "bindings" to rules.bindings.size,
              "loc" to nodes.sumOf { it.size.loc },
              "members" to membersOut.members.size,
              "memberEdges" to membersOut.edges.size,
            ),
        ),
      files = files,
      containers =
        containment.containers.map { c ->
          ContainerOut(c.id, c.kind, c.parent, c.name, c.qualified, c.depth, containerSizes[c.id] ?: Size(0, 0, 0))
        },
      features =
        containment.features.map { f ->
          val members = byFeature[f.id].orEmpty()
          FeatureOut(
            f.id, f.module, f.pkg, f.packageContainers,
            Size(members.sumOf { units.nodes.getValue(it).loc }, members.sumOf { units.declCounts[it] ?: 0 }, members.size),
            entryFeatures.count { it == f.id },
          )
        },
      nodes = nodes,
      edges = edges,
      cells = cells,
      entrypoints = entries,
      boundaries =
        rules.boundaries.map { b ->
          BoundaryOut(b.system, b.kind, b.op, b.target, b.caller, units.ofDecl(b.caller), b.access, b.label, b.operation, b.method, b.path, b.file, b.line)
        },
      bindings =
        rules.bindings.map { b ->
          BindingOut(b.framework, b.graph, classByDotted[b.graph]?.let(units::ofDecl), b.type, b.qualifier, b.provider, units.ofDecl(b.provider), b.kind, b.scope, b.variant, b.reachable, b.file, b.line)
        },
      navigations = rules.navigations.map { NavigationOut(it.from, it.to, it.op, it.file, it.line) },
      bundles = Bundles(wraps(), argGroups()),
      patterns =
        Patterns(
          patternVector("target", nodeIds, roles, loops),
          containment.features.map { patternVector(it.id, byFeature[it.id].orEmpty(), roles, loops) },
          loops,
        ),
      traces = traces,
    )
    return export to membersOut
  }

  private val nodeIndex: Map<String, Int> = nodeIds.withIndex().associate { it.value to it.index }

  private fun membersExport(edgeIndex: Map<Triple<String, String, String>, Int>): MembersExport {
    val drafts = members.finish(nodeIndex)
    val memberIndex = drafts.withIndex().associate { it.value.id to it.index }
    val nested =
      units.decls.values
        .filter { members.isStructural(it) && units.ofDecl(it.sym).let { n -> n != null && n != it.sym && n in nodeIndex } }
        .sortedWith(compareBy({ nodeIndex.getValue(units.ofDecl(it.sym)!!) }, { Units.span(it.span)?.first ?: 0 }, { it.sym }))
    val classIndex = nested.withIndex().associate { it.value.sym to it.index }
    val classes =
      nested.map { c ->
        val span = Units.span(c.span)
        NestedClassOut(c.sym, nodeIndex.getValue(units.ofDecl(c.sym)!!), c.name, c.file?.let(fileIndex::get), span?.toList().orEmpty(), c.owner?.let(classIndex::get))
      }
    val out =
      drafts.map { m ->
        MemberOut(
          id = m.id,
          n = nodeIndex.getValue(m.node),
          k = m.kind,
          name = m.name,
          sig = m.signature,
          f = m.file?.let(fileIndex::get),
          l = m.span?.let { listOf(it[0], it[2]) }.orEmpty(),
          s = m.size,
          v = m.visibility,
          fl = m.flags,
          cell = m.cells.toList(),
          p = m.parent?.let(memberIndex::get),
          c = m.nestedClass?.let(classIndex::get),
          lam = m.lambdas,
          np = nonProduction(m.id),
        )
      }
    val edges =
      memberAggs.mapNotNull { (k, a) ->
        val from = memberIndex[k.first] ?: return@mapNotNull null
        val to = memberIndex[k.second] ?: return@mapNotNull null
        val fromNode = drafts[from].node
        val toNode = drafts[to].node
        val nodeEdge = if (fromNode == toNode) null else edgeIndex[Triple(fromNode, toNode, k.third)]
        MemberEdgeOut(from, to, k.third, a.evidence.size, a.sites.take(MEMBER_EVIDENCE_SITES).map(::site), a.detail, nodeEdge)
      }
    val counts = TreeMap<String, Int>()
    for (m in out) counts.merge("members.${m.k}", 1, Int::plus)
    for (e in edges) {
      counts.merge("edges.${e.k}", 1, Int::plus)
      if (e.e == null) counts.merge("edges.${e.k}.inNode", 1, Int::plus)
    }
    counts["classes"] = classes.size
    counts["members"] = out.size
    counts["edges"] = edges.size
    return MembersExport(target = target, classes = classes, members = out, edges = edges, counts = counts)
  }

  private val previewAnnotated: Set<String> =
    facts.annotations.filter { "Preview" in it.annFq.substringAfterLast('/') }.mapTo(HashSet()) { it.sym }
  private val testFiles: Set<String> =
    facts.files.filter { it.sourceSet?.contains("test", ignoreCase = true) == true }.mapTo(HashSet()) { it.path }

  /**
   * Which clause of the tracer's production check puts a location outside production: `test`,
   * `preview` or `fake`. [Program.isStaged] decides whether one does; this only names it.
   */
  fun nonProduction(location: String): String? {
    if (!program.isStaged(location)) return null
    val id = withoutContext(location.removeSuffix(ELEMENT))
    val start = units.nodesById[id]?.enclosingDecl ?: id.takeIf { it in units.decls } ?: id.substringBeforeLast("#<")
    return generateSequence(units.decls[start]) { d -> d.owner?.let { units.decls[it] } }.firstNotNullOfOrNull { d ->
      when {
        d.file in testFiles -> "test"
        d.sym in previewAnnotated -> "preview"
        (d.kind in CLASS_KINDS || d.kind == "enumEntry") && FAKE_NAME.containsMatchIn(d.name) -> "fake"
        else -> null
      }
    } ?: "staged"
  }

  private fun nodeNonProduction(node: String): String? =
    when {
      !staged(node) -> null
      node.startsWith("top:") -> "test"
      else -> nonProduction(node)
    }

  private fun containerSizes(): Map<String, Size> {
    val out = HashMap<String, IntArray>()
    for ((node, chain) in containment.chain) {
      val info = units.nodes.getValue(node)
      for (c in chain) {
        val s = out.getOrPut(c) { IntArray(3) }
        s[0] += info.loc
        s[1] += units.declCounts[node] ?: 0
        s[2] += 1
      }
    }
    return out.mapValues { Size(it.value[0], it.value[1], it.value[2]) }
  }

  private val program by lazy { Program(facts, derived) }

  private fun staged(node: String): Boolean = node.startsWith("class:") && program.isStaged(node) || node.startsWith("top:") && facts.files.firstOrNull { it.path == node.removePrefix("top:") }?.sourceSet?.contains("test", true) == true
}

const val MEMBERS_FILE = "altitude-members.json"
private val FAKE_NAME = Regex("Fake(?![a-z])")

internal fun round3(x: Double): Double = Math.round(x * 1000) / 1000.0
