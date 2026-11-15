package com.ryanmoelter.altitude.solver

import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.FanOutFact
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FlowFact

private const val MAX_WRAPPER_LINES = 15
private const val MAX_WRAPPER_CALLS = 12
private const val MAX_HELPER_CLASS_LINES = 40
private const val MAX_HOLDER_CLASS_LINES = 250
private const val MAX_HOLDER_CONSTRUCTIONS = 40
private const val MAX_WRAPPER_NESTING = 3
private val DISPATCHED = setOf("open", "abstract", "override", "expect")
private val CONTEXT = Regex("""~\d+""")
private val CLASS_KINDS = setOf("class", "object")

/** A flow from a copied property to the one it copies, or back. */
const val MERGE = "merge"

/** An ID without the `~N` that marks a copy made for one call site. */
fun withoutContext(id: String): String = if ('~' in id) id.replace(CONTEXT, "") else id

/** The number after `~` in a copy's ID, an index into [Expansion.contexts]. */
fun contextOf(id: String): Int? = CONTEXT.find(id)?.value?.drop(1)?.toInt()

/** [facts] with wrapper functions copied per call site; `contexts[N]` is the call behind `~N`. */
class Expansion(val facts: Facts, val contexts: List<String>)

/** What is copied together: the declarations [entries] are called through, and all that runs with them. */
private class CopyUnit(val entries: Set<String>, val members: Set<String>, val spans: List<DeclFact>)

/**
 * Copies code per call site, so what one caller passes in comes back only to that caller.
 * - A small function that takes a function value is copied for each static call of it. A class
 *   constructed nowhere but inside such a function is copied with it, fields included.
 * - A class that takes a function value in its constructor and has no subclass is copied for each
 *   construction, members and fields included. A call from outside to a member of such a class
 *   still reaches the original, which sees every copy's fields, as does a call inside a copy to
 *   the copied function itself.
 * Classes are copied first, so a wrapper called inside a class copy gets a copy of its own.
 * A copied call site names its copy as its target, which is how a later round knows to skip it.
 */
fun expand(facts: Facts): Expansion {
  val decls = facts.decls.sortedBy { it.sym }.groupBy { it.sym }.mapValues { it.value.first() }
  val owned = facts.decls.filter { it.owner != null }.groupBy { it.owner!! }
  fun body(root: String, includeRoot: Boolean): Set<String> {
    val all = LinkedHashSet<String>()
    val queue = ArrayDeque(listOf(root))
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      if ((current != root || includeRoot) && !all.add(current)) continue
      for (child in owned[current].orEmpty()) queue += child.sym
    }
    return all
  }
  val callsByCaller = facts.calls.groupBy { it.callerDecl }
  val callsByTarget = facts.calls.groupBy { it.target }
  fun constructors(cls: DeclFact) = owned[cls.sym].orEmpty().filter { it.kind == "ctor" }

  val wrappers = LinkedHashMap<String, MutableSet<String>>()
  for (decl in facts.decls.sortedBy { it.sym }) {
    if (decl.kind != "fun" || decl.sym in wrappers) continue
    if (decl.modifiers.any { it in DISPATCHED } || lines(decl) > MAX_WRAPPER_LINES) continue
    if (owned[decl.sym].orEmpty().none { it.kind == "param" && it.fnTyped }) continue
    val members = body(decl.sym, includeRoot = true)
    val inner = members.flatMap { callsByCaller[it].orEmpty() }
    if (inner.size > MAX_WRAPPER_CALLS || inner.any { it.target == decl.sym }) continue
    wrappers[decl.sym] = members.toMutableSet()
  }
  val owner = HashMap<String, String>()
  for ((wrapper, members) in wrappers) for (member in members) owner.putIfAbsent(member, wrapper)
  val spans = wrappers.keys.associateWith { mutableListOf(decls.getValue(it)) }
  val subclassed = facts.supertypes.mapTo(HashSet()) { it.sup }
  val holders = ArrayList<CopyUnit>()
  for (cls in facts.decls.filter { it.kind == "class" }.sortedBy { it.sym }) {
    val constructions = constructors(cls).flatMap { callsByTarget[it.sym].orEmpty() }
    val makers = constructions.map { owner[it.callerDecl] }.distinct()
    val wrapper = makers.singleOrNull()
    if (wrapper != null && lines(cls) <= MAX_HELPER_CLASS_LINES) {
      wrappers.getValue(wrapper) += body(cls.sym, includeRoot = false)
      spans.getValue(wrapper) += cls
      continue
    }
    if (cls.sym in subclassed || lines(cls) > MAX_HOLDER_CLASS_LINES) continue
    if (constructions.isEmpty() || constructions.size > MAX_HOLDER_CONSTRUCTIONS) continue
    val parameters = constructors(cls).flatMap { owned[it.sym].orEmpty() }
    if (parameters.none { it.kind == "param" && it.fnTyped }) continue
    holders += CopyUnit(constructors(cls).mapTo(HashSet()) { it.sym }, body(cls.sym, includeRoot = false), listOf(cls))
  }
  val functions = wrappers.map { (wrapper, members) -> CopyUnit(setOf(wrapper), members, spans.getValue(wrapper)) }

  val contexts = ArrayList<String>()
  var current = facts
  // The second round of classes copies those constructed inside a copy from the first.
  for (units in listOf(holders, holders)) current = copy(current, units, decls, contexts)
  // A copy calls the original of any wrapper inside it; the next round copies that wrapper for it.
  for (round in 1..MAX_WRAPPER_NESTING) {
    val before = contexts.size
    current = copy(current, functions, decls, contexts)
    if (contexts.size == before) break
  }
  return Expansion(current, contexts)
}

private fun copy(
  facts: Facts,
  units: List<CopyUnit>,
  decls: Map<String, DeclFact>,
  contexts: MutableList<String>,
): Facts {
  val callsByCaller = facts.calls.groupBy { it.callerDecl }
  val nodesByDecl = facts.nodes.groupBy { it.enclosingDecl }
  val argsByCall = facts.args.groupBy { it.call }
  val lambdaCallsByCall = facts.libraryLambdaCalls.groupBy { it.call }
  val overridesBySym = facts.overrides.groupBy { it.sym }
  val flowsByFile = facts.flows.groupBy { it.at.substringBefore(':') }
  val boundaryFrom = facts.flows.groupBy { it.from }
  val boundaryTo = facts.flows.groupBy { it.to }
  val nodeDecls = facts.nodes.associate { it.id to it.enclosingDecl }
  val constructorsByClass = decls.values.filter { it.kind == "ctor" }.groupBy({ it.owner }, { it.sym })

  val newDecls = ArrayList<DeclFact>()
  val newNodes = ArrayList(facts.nodes)
  val newCalls = ArrayList(facts.calls)
  val newArgs = ArrayList(facts.args)
  val newFlows = LinkedHashSet<FlowFact>()
  val redirected = HashSet<FlowFact>()
  val newLambdaCalls = ArrayList(facts.libraryLambdaCalls)
  val newOverrides = ArrayList(facts.overrides)
  val siteMarks = HashMap<String, String>()

  for (unit in units) {
    val members = unit.members
    val sites =
      facts.calls
        .filter { it.target in unit.entries && withoutContext(it.callerDecl) !in members }
        .filter { it.dispatch == "static" || decls[it.target]?.kind == "ctor" }
        .sortedBy { it.id }
    if (sites.isEmpty()) continue
    val innerCalls = members.flatMap { callsByCaller[it].orEmpty() }
    val innerNodes = members.flatMap { nodesByDecl[it].orEmpty() }
    val renamed = HashSet(members)
    innerNodes.mapTo(renamed) { it.id }
    innerCalls.mapTo(renamed) { it.id }
    // An earlier copy of this unit lies in the same lines; an edge into another unit's copy does not.
    fun isOwn(id: String) = contextOf(id) == null || withoutContext(id).substringBefore('#') !in renamed
    val innerFlows =
      unit.spans.map { it.file }.distinct().flatMap { flowsByFile[it].orEmpty() }.filterTo(LinkedHashSet()) { flow ->
        isOwn(flow.from) && isOwn(flow.to) && unit.spans.any { contains(it, flow.at) }
      }

    for (site in sites) {
      val mark = "~${contexts.size}"
      contexts += site.id
      siteMarks[site.id] = mark
      fun rename(id: String): String {
        val head = id.substringBefore('#')
        return when {
          head != id && head in renamed -> head + mark + id.removePrefix(head)
          id in renamed -> id + mark
          else -> id
        }
      }
      for (member in members) {
        val decl = decls[member] ?: continue
        newDecls += decl.copy(sym = rename(decl.sym), owner = decl.owner?.let(::rename))
        for (override in overridesBySym[member].orEmpty()) newOverrides += override.copy(sym = rename(member))
      }
      for (node in innerNodes) {
        newNodes += node.copy(id = rename(node.id), enclosingDecl = rename(node.enclosingDecl), target = node.target?.let(::rename))
      }
      for (call in innerCalls) {
        newCalls += call.copy(
          id = rename(call.id),
          callerDecl = rename(call.callerDecl),
          target = rename(call.target),
          receiver = call.receiver.map(::rename),
          extReceiver = call.extReceiver.map(::rename),
          result = call.result?.let(::rename),
        )
        for (arg in argsByCall[call.id].orEmpty()) {
          newArgs += arg.copy(call = rename(arg.call), param = rename(arg.param), node = rename(arg.node))
        }
        for (row in lambdaCallsByCall[call.id].orEmpty()) newLambdaCalls += row.copy(call = rename(row.call))
      }
      for (flow in innerFlows) {
        val copy = flow.copy(from = rename(flow.from), to = rename(flow.to))
        if (copy != flow) newFlows += copy
      }
      // Code outside the copy names the original: it reads the original property, and a member it
      // calls runs the original body, whichever copy the receiver is. So the original property
      // holds every copy's value. The original's value reaches a copy only when something other
      // than construction writes the property, since construction is what the copies keep apart.
      for (member in members) {
        val decl = decls[member] ?: continue
        if (decl.kind != "prop" || decls[decl.owner]?.kind !in CLASS_KINDS) continue
        val at = "${decl.file}:${decl.span}"
        newFlows += FlowFact(rename(member), member, MERGE, at)
        val constructing = constructorsByClass[decl.owner].orEmpty() + decl.owner
        fun constructs(flow: FlowFact) =
          flow in innerFlows && (nodeDecls[flow.from] ?: flow.from.substringBefore('#')) in constructing
        if (boundaryTo[member].orEmpty().any { it.kind != MERGE && !constructs(it) }) {
          newFlows += FlowFact(member, rename(member), MERGE, at)
        }
      }
      // The call's own argument, receiver and return edges move from the original to this copy.
      val passed = argsByCall[site.id].orEmpty().map { it.node } + site.receiver + site.extReceiver
      for (flow in passed.distinct().flatMap { boundaryFrom[it].orEmpty() }) {
        if (flow.to.substringBefore('#') !in unit.entries || flow in innerFlows) continue
        redirected += flow
        newFlows += flow.copy(to = rename(flow.to))
      }
      for (flow in site.result?.let { boundaryTo[it] }.orEmpty()) {
        if (flow.from.substringBefore('#') !in unit.entries) continue
        redirected += flow
        newFlows += flow.copy(from = rename(flow.from))
      }
    }
  }
  return facts.copy(
    decls = facts.decls + newDecls,
    overrides = newOverrides,
    nodes = newNodes,
    calls = newCalls.map { call -> siteMarks[call.id]?.let { call.copy(target = call.target + it) } ?: call },
    args =
      newArgs.map { arg ->
        val mark = siteMarks[arg.call] ?: return@map arg
        arg.copy(param = arg.param.substringBefore('#') + mark + arg.param.removePrefix(arg.param.substringBefore('#')))
      },
    flows = facts.flows.filter { it !in redirected } + newFlows,
    libraryLambdaCalls = newLambdaCalls,
  )
}

private fun lines(decl: DeclFact): Int {
  val span = decl.span ?: return Int.MAX_VALUE
  val first = span.substringBefore(':').toIntOrNull() ?: return Int.MAX_VALUE
  val last = span.substringAfter('-').substringBefore(':').toIntOrNull() ?: return Int.MAX_VALUE
  return last - first + 1
}

private fun position(text: String): Pair<Int, Int>? {
  val parts = text.split(':')
  return (parts.getOrNull(0)?.toIntOrNull() ?: return null) to (parts.getOrNull(1)?.toIntOrNull() ?: return null)
}

/** Whether the position `relpath:line:col-line:col` starts inside the declaration. */
private fun contains(decl: DeclFact, at: String): Boolean {
  val file = decl.file ?: return false
  if (!at.startsWith("$file:")) return false
  val span = decl.span ?: return false
  val start = position(span.substringBefore('-')) ?: return false
  val end = position(span.substringAfter('-')) ?: return false
  val point = position(at.removePrefix("$file:").substringBefore('-')) ?: return false
  val order = compareBy<Pair<Int, Int>>({ it.first }, { it.second })
  return order.compare(start, point) <= 0 && order.compare(point, end) <= 0
}

/** Folds what the solver derived for copies back onto the declarations and calls they copy. */
fun withoutContexts(derived: Derived): Derived {
  fun fold(flow: FlowFact) = flow.copy(from = withoutContext(flow.from), to = withoutContext(flow.to))
  val fnValues =
    derived.fnValues
      .map { it.copy(call = withoutContext(it.call), value = withoutContext(it.value), witness = it.witness.map(::fold).filter { flow -> flow.from != flow.to }) }
      .groupBy { it.call to it.value }
      .map { (_, same) -> same.minWith(compareBy({ it.witness.size }, { it.witness.toString() })) }
      .sortedWith(compareBy({ it.call }, { it.value }))
  val values = fnValues.groupBy { it.call }.mapValues { it.value.size }
  return derived.copy(
    flows = derived.flows.map(::fold).filter { it.from != it.to }.distinct(),
    contextFlows = derived.flows,
    fnValues = fnValues,
    callEdges =
      derived.callEdges
        .map {
          it.copy(
            call = withoutContext(it.call),
            caller = withoutContext(it.caller),
            callee = withoutContext(it.callee),
            invoker = it.invoker?.let(::withoutContext),
            cell = it.cell?.let(::withoutContext),
          )
        }
        .distinct()
        .sortedBy { it.toString() },
    cells =
      derived.cells
        .map { it.copy(id = withoutContext(it.id), sym = it.sym?.let(::withoutContext)) }
        .distinct()
        .groupBy { it.id }
        .map { (_, same) -> same.minWith(compareBy({ it.sym.orEmpty() }, { it.mechanism })) },
    cellWrites = derived.cellWrites.map { it.copy(cell = withoutContext(it.cell), node = withoutContext(it.node)) }.distinct(),
    cellReads = derived.cellReads.map { it.copy(cell = withoutContext(it.cell), node = withoutContext(it.node)) }.distinct(),
    fanOuts =
      derived.fanOuts
        .map { withoutContext(it.call) }
        .distinct()
        .sorted()
        .map { FanOutFact(it, values[it] ?: 0) },
    unmodelledLambdaCalls =
      derived.unmodelledLambdaCalls
        .map { it.copy(call = withoutContext(it.call)) }
        .distinct()
        .sortedWith(compareBy({ it.call }, { it.callee })),
  )
}
