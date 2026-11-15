package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.solver.withoutContext
import com.ryanmoelter.altitude.trace.Site
import java.util.TreeMap
import java.util.TreeSet

const val VARIABLES_FILE = "altitude-variables.json"

/** Locations a backward walk for one variable's sources may visit before it gives up. */
private const val SOURCE_WALK_CAP = 400
private const val LABEL_LENGTH = 24
private val REFERENCE_KINDS = setOf("localRef", "paramRef", "thisRef")
private val ACCESSOR_PARTS = listOf("#<delegate>", "#<get>", "#<set>")
private val START = Regex("""(\d+):(\d+)-""")
private const val REMEMBER = "fun:androidx/compose/runtime/remember("

/** A variable before the export numbers it: [line] and [column] are where it is declared. */
class VariableDraft(
  val id: String,
  val member: String,
  val kind: String,
  val name: String,
  val line: Int,
  val column: Int,
  val lambda: String?,
  val type: String?,
  val delegated: Boolean = false,
) {
  /** Lambdas that capture the variable. */
  val captures = sortedSetOf<String>()
  var component: String? = null
  var remembered = false
  /** Initialised from a cell read, such as `collectAsState()`. */
  var stateRead = false
  var label: String? = null
}

/**
 * The value holders inside members: parameters, receivers, locals and lambda parameters. A
 * reference to one (`localRef`, `paramRef`, `thisRef`, a capture inside a lambda included) and a
 * delegated local's accessors stand for the variable itself. Anything else a hop lands on is an
 * expression temporary, which [table] adds only when asked to. A local that holds a cell is its
 * own member, so its variable lives in that member, whose parent is the function around it.
 */
class Variables(
  private val units: Units,
  private val members: Members,
  facts: Facts,
  derived: Derived,
  /** Lambdas that run as composable content. */
  private val composableLambdas: Set<String>,
  /** Lambdas a composable passes as an event callback. */
  private val eventLambdas: Set<String>,
) {
  private val decls = units.decls
  private val drafts = HashMap<String, VariableDraft>()
  private val alias = HashMap<String, String>()
  private val flows: List<FlowFact> = (facts.flows + derived.flows).filter { it.kind != "di" }
  private val callsById = facts.calls.associateBy { it.id }
  private val readSpans: Set<String> = derived.cellReads.mapTo(HashSet()) { it.node.substringBeforeLast(':') }

  init {
    val delegatedLocals = decls.values.filter { it.kind == "getter" && "delegated" in it.modifiers }.mapNotNullTo(HashSet()) { it.owner }
    for (d in decls.values) {
      if (d.kind != "param" && d.kind != "local") continue
      val member = members.ofDecl(d.sym) ?: continue
      val ownerKind = d.owner?.let { decls[it]?.kind }
      val kind = if (d.kind == "local") "local" else if (ownerKind == "lambda") "lambdaParam" else "param"
      val (line, column) = start(d.span) ?: (0 to 0)
      add(VariableDraft(d.sym, member, kind, d.name, line, column, lambdaOf(d.owner), shortType(d.type), delegated = d.sym in delegatedLocals))
    }
    val receivers = TreeSet<String>()
    for (f in flows) for (l in listOf(f.from, f.to)) if (l.endsWith("#<this>") || l.endsWith("#<recv>")) receivers += withoutContext(l)
    for (n in facts.nodes) if (n.kind == "thisRef") n.target?.let { receivers += it }
    for (r in receivers) {
      val base = r.substringBeforeLast("#<")
      val decl = decls[base] ?: continue
      val member = members.ofDecl(base) ?: continue
      val (line, column) = start(decl.span) ?: (0 to 0)
      add(VariableDraft(r, member, "receiver", if (r.endsWith("#<this>")) "this" else "receiver", line, column, if (decl.kind == "lambda") base else lambdaOf(base), null))
    }
    for (f in flows) {
      if (f.kind != "capture") continue
      val source = drafts[f.from] ?: continue
      units.nodesById[f.to]?.let { lambdaOf(it.enclosingDecl) }?.let { source.captures += it }
    }
    for (f in flows) {
      val local = drafts[f.to]?.takeIf { it.kind == "local" } ?: continue
      if (f.kind == "destructure") local.component = decls[f.from]?.name ?: simpleName(f.from)
      val result = units.nodesById[f.from]?.takeIf { it.kind == "callResult" } ?: continue
      if (result.id.substringBeforeLast(':') in readSpans) local.stateRead = true
      val call = result.target?.let(callsById::get) ?: continue
      if (call.target.startsWith(REMEMBER)) local.remembered = true
    }
    val lambdaCallee = HashMap<String, String>()
    val lambdaOfExpr = facts.nodes.filter { it.kind == "lambdaExpr" }.associate { it.id to it.target }
    for (a in facts.args) lambdaOfExpr[a.node]?.let { lambda -> callsById[a.call]?.let { lambdaCallee.putIfAbsent(lambda, simpleName(it.target)) } }
    for (d in drafts.values) if (d.kind == "lambdaParam" && d.name == "it") d.label = decls[d.id]?.owner?.let(lambdaCallee::get)?.let { "$it → it" }
    for (d in drafts.values) if (d.kind == "local") for (part in ACCESSOR_PARTS) alias[d.id + part] = d.id
    for (n in facts.nodes) {
      if (n.kind !in REFERENCE_KINDS || n.id in drafts) continue
      val target = n.target ?: continue
      if (target in drafts) alias[n.id] = target
    }
  }

  private fun add(draft: VariableDraft) {
    drafts.putIfAbsent(draft.id, draft)
  }

  private fun start(span: String?): Pair<Int, Int>? = span?.let { START.find(it) }?.let { it.groupValues[1].toInt() to it.groupValues[2].toInt() }

  private fun shortType(type: String?): String? = type?.replace(TYPE_PACKAGE, "")

  /** The innermost lambda a declaration sits in, below its member. */
  fun lambdaOf(start: String?): String? {
    var current = start
    var guard = 0
    while (current != null && guard++ < 200) {
      val decl = decls[current] ?: return null
      if (decl.kind == "lambda") return current
      if (members.draft(current) != null || decl.kind in CLASS_KINDS) return null
      current = decl.owner
    }
    return null
  }

  private fun bare(location: String): String {
    var id = withoutContext(location)
    while (id.endsWith(ELEMENT)) id = id.removeSuffix(ELEMENT)
    return id
  }

  /** The variable a location holds or reads, leaving expression temporaries out. */
  fun idOf(location: String): String? {
    val id = bare(location)
    if (id in drafts) return id
    return alias[id]
  }

  private fun temp(location: String): VariableDraft? {
    val id = bare(location)
    if (members.draft(id) != null) return null
    val member = members.ofLocation(id) ?: return null
    val node = units.nodesById[id]
    val (line, column) = start(id) ?: decls[id.substringBeforeLast("#<")]?.span?.let(::start) ?: (0 to 0)
    val lambda = lambdaOf(node?.enclosingDecl ?: id.substringBeforeLast("#<"))
    return VariableDraft(id, member, "temp", tempLabel(id), line, column, lambda, shortType(node?.type))
  }

  private fun tempLabel(id: String): String {
    val node = units.nodesById[id]
    val label =
      when (node?.kind) {
        "callResult" -> node.target?.let(callsById::get)?.target?.let { simpleName(it) + "()" } ?: "call"
        "propRef" -> node.target?.let { decls[it]?.name ?: simpleName(it) } ?: "property"
        "objectCreation" -> node.type?.let { it.substringBefore('<').substringAfterLast('.') + "()" } ?: "object"
        "literal" -> node.text ?: "literal"
        "lambdaExpr" -> "lambda"
        "callableRef" -> "::" + (node.target?.let(::simpleName) ?: "ref")
        null -> when {
          id.endsWith("#<ret>") -> "return"
          "#<" in id -> id.substringAfterLast("#<").removeSuffix(">")
          else -> simpleName(id)
        }
        else -> node.kind
      }
    return if (label.length > LABEL_LENGTH) label.take(LABEL_LENGTH - 3) + "..." else label
  }

  private fun simpleName(sym: String): String = sym.substringBefore("#<").substringBefore('(').substringBefore('@').substringAfterLast('/').substringAfterLast('.')

  /**
   * Numbers the variables, with a temporary for each of [hopLocations] that holds no variable, and
   * finds the value edges between them. Members outside [memberIndex] drop their variables.
   */
  fun table(memberIndex: Map<String, Int>, hopLocations: Collection<String>, memberEdgeIndex: Map<Triple<String, String, String>, Int>, site: (Site) -> String): VariableTable {
    val all = HashMap<String, VariableDraft>()
    for ((id, d) in drafts) if (d.member in memberIndex) all[id] = d
    for (l in hopLocations) {
      if (idOf(l) != null) continue
      val id = bare(l)
      if (id in all) continue
      temp(l)?.takeIf { it.member in memberIndex }?.let { all[id] = it }
    }
    val sorted = all.values.sortedWith(compareBy({ memberIndex.getValue(it.member) }, { it.line }, { it.column }, { it.kind == "temp" }, { it.id }))
    val index = sorted.withIndex().associate { it.value.id to it.index }
    val outputs = flows.filter { it.kind == "arg" || it.kind == "receiver" }.mapNotNullTo(HashSet()) { idOf(it.from) }
    val lambdaSyms = sorted.mapNotNullTo(HashSet()) { it.lambda } + decls.values.filter { it.kind == "lambda" }.map { it.sym }.filter { members.ofDecl(it) in memberIndex }
    val lambdaDrafts =
      lambdaSyms.map { sym ->
        val d = decls.getValue(sym)
        val (line, column) = start(d.span) ?: (0 to 0)
        Triple(sym, memberIndex.getValue(members.ofDecl(sym)!!), line to column)
      }.sortedWith(compareBy({ it.second }, { it.third.first }, { it.third.second }, { it.first }))
    val lambdaIndex = lambdaDrafts.withIndex().associate { it.value.first to it.index }
    val ordinal = HashMap<Int, Int>()
    val lambdas =
      lambdaDrafts.map { (sym, member, _) ->
        val d = decls.getValue(sym)
        val span = Units.span(d.span)
        LambdaOut(sym, member, ordinal.merge(member, 1, Int::plus)!! - 1, span?.toList().orEmpty(), lambdaOf(d.owner)?.let(lambdaIndex::get), sym in composableLambdas)
      }
    val vars =
      sorted.map { d ->
        VariableOut(
          d.id, memberIndex.getValue(d.member), d.kind, d.name, d.line, d.lambda?.let(lambdaIndex::get), d.type,
          lbl = d.label, dl = d.delegated, ds = d.component, rem = d.remembered,
          cap = d.captures.mapNotNull(lambdaIndex::get).sorted(), rank = rankOf(d, outputs),
        )
      }
    return VariableTable(index, vars, lambdas, edges(index, memberIndex, memberEdgeIndex, site), this)
  }

  /** The most specific of: a cell read, a capture into an event callback, a value passed on. */
  private fun rankOf(d: VariableDraft, outputs: Set<String>): String =
    when {
      d.kind == "temp" -> "other"
      d.stateRead || d.delegated || members.draft(d.member)?.kind == "cell" -> "stateRead"
      d.captures.any { it in eventLambdas } -> "eventCapture"
      d.id in outputs -> "output"
      else -> "other"
    }

  private class Agg {
    val evidence = TreeSet<String>()
    val sites = TreeSet<Site>()
    val kinds = TreeMap<String, Int>()
  }

  /**
   * One edge from each variable whose value reaches another through expressions alone. The walk
   * from each variable runs backward and stops at variables and members, so an edge never jumps
   * over a variable that holds the value on the way.
   */
  private fun edges(index: Map<String, Int>, memberIndex: Map<String, Int>, memberEdgeIndex: Map<Triple<String, String, String>, Int>, site: (Site) -> String): List<MemberEdgeOut> {
    val incoming = flows.groupBy { it.to }
    val locationsOf = HashMap<String, MutableList<String>>()
    for (id in index.keys) if (drafts[id] != null) locationsOf.getOrPut(id) { ArrayList() } += id
    for ((location, id) in alias) if (id in index) locationsOf.getOrPut(id) { ArrayList() } += location
    val aggs = TreeMap<Pair<Int, Int>, Agg>(compareBy({ it.first }, { it.second }))
    for ((target, locations) in locationsOf) {
      val b = index.getValue(target)
      val seen = HashSet<String>(locations)
      val queue = ArrayDeque<Pair<String, FlowFact>>()
      for (l in locations) for (f in incoming[l].orEmpty()) queue += f.from to f
      while (queue.isNotEmpty()) {
        val (from, entry) = queue.removeFirst()
        val source = idOf(from)
        if (source != null) {
          val a = index[source]
          if (a != null && a != b) aggs.getOrPut(a to b) { Agg() }.let { agg ->
            if (agg.evidence.add(entry.at)) {
              (Site.of(entry.at) ?: siteOf(entry.at, units))?.let { agg.sites += it }
              agg.kinds.merge(entry.kind, 1, Int::plus)
            }
          }
          continue
        }
        if (members.draft(bare(from)) != null || seen.size >= SOURCE_WALK_CAP || !seen.add(from)) continue
        for (f in incoming[from].orEmpty()) queue += f.from to entry
      }
    }
    val varMembers = HashMap<Int, String>()
    for ((id, i) in index) drafts[id]?.let { varMembers[i] = it.member }
    return aggs.map { (k, agg) ->
      val ma = varMembers[k.first]
      val mb = varMembers[k.second]
      val memberEdge = if (ma == null || mb == null || ma == mb) null else memberEdgeIndex[Triple(ma, mb, "value")]
      MemberEdgeOut(k.first, k.second, "value", agg.evidence.size, agg.sites.take(MEMBER_EVIDENCE_SITES).map(site), agg.kinds, memberEdge)
    }
  }
}

/** The numbered variables, and the lookup hops use to name the variable at each end. */
class VariableTable(
  private val index: Map<String, Int>,
  val vars: List<VariableOut>,
  val lambdas: List<LambdaOut>,
  val edges: List<MemberEdgeOut>,
  private val variables: Variables,
) {
  fun of(location: String): Int? {
    variables.idOf(location)?.let { return index[it] }
    var id = withoutContext(location)
    while (id.endsWith(ELEMENT)) id = id.removeSuffix(ELEMENT)
    return index[id]
  }

  fun export(target: String, counts: Map<String, Int>) = VariablesExport(target = target, lambdas = lambdas, vars = vars, edges = edges, counts = counts)
}
