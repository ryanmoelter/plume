package com.ryanmoelter.altitude.solver

import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FanOutFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.FnValueFact
import com.ryanmoelter.altitude.facts.SupertypeFact

private const val THIS = "#<this>"
private const val RECEIVER = "#<recv>"
private const val RETURN = "#<ret>"
private val ACCESSORS = listOf("#<get>", "#<set>")

/**
 * Derives which function values reach each invoke, and which declarations each call can run.
 *
 * The analysis is flow-insensitive and field-based: a property, a parameter and a local are each
 * one location whatever object or call they belong to. Values move along `flow` edges until
 * nothing changes; reaching an invoke adds the edges that bind its arguments and result.
 */
fun solve(facts: Facts): Derived = Solver(facts).run()

/** A lambda, or a function, constructor or property named by a callable reference. */
private data class Value(val sym: String, val bound: Boolean)

/** How a value first got to a location: over [edge], or as the node that creates it. */
private class Arrival(val edge: FlowFact?)

private class Solver(private val facts: Facts) {
  private val decls: Map<String, DeclFact> =
    facts.decls.sortedBy { it.sym }.groupBy { it.sym }.mapValues { it.value.first() }
  private val parameters: Map<String, List<String>> =
    facts.decls
      .filter { it.kind == "param" && it.owner != null && it.index != null }
      .groupBy { it.owner!! }
      .mapValues { (_, all) -> all.sortedBy { it.index }.map { it.sym }.distinct() }
  private val calls = facts.calls.sortedBy { it.id }
  private val argsByCall: Map<String, List<ArgFact>> = facts.args.groupBy { it.call }

  private val edges = HashMap<String, MutableList<FlowFact>>()
  private val knownEdges = HashSet<FlowFact>()
  private val derivedFlows = ArrayList<FlowFact>()
  private val reach = HashMap<String, LinkedHashMap<Value, Arrival>>()
  private val work = ArrayDeque<Pair<String, Value>>()

  private val invokesByFunction = HashMap<String, MutableList<CallFact>>()
  private val samCallsByReceiver = HashMap<String, MutableList<CallFact>>()
  private val unmodelledByArgument = HashMap<String, MutableList<String>>()

  private val fnValues = LinkedHashMap<Pair<String, Value>, FnValueFact>()
  private val callEdges = LinkedHashSet<CallEdgeFact>()

  private val hierarchy = Hierarchy(facts, decls)

  fun run(): Derived {
    for (flow in facts.flows.sortedWith(flowOrder)) addEdge(flow, derived = false)
    overrideFlows()
    indexCalls()
    for (node in facts.nodes.sortedBy { it.id }) {
      val target = node.target ?: continue
      when (node.kind) {
        "lambdaExpr" -> arrive(node.id, Value(target, bound = true), Arrival(null))
        "callableRef" -> arrive(node.id, Value(target, node.bound), Arrival(null))
      }
    }
    while (work.isNotEmpty()) {
      val (location, value) = work.removeFirst()
      for (edge in edges[location].orEmpty().toList()) arrive(edge.to, value, Arrival(edge))
    }
    staticCallEdges()
    val reaching = fnValues.keys.groupBy({ it.first }, { it.second.sym })
    val fanOuts =
      calls
        .filter { it.dispatch == "invokeFnValue" }
        .map { FanOutFact(it.id, reaching[it.id].orEmpty().distinct().size) }
    return Derived(derivedFlows, fnValues.values.toList(), callEdges.toList(), fanOuts)
  }

  private fun indexCalls() {
    val unmodelled = facts.unmodelledLambdaCalls.map { it.call }.toSet()
    for (call in calls) {
      if (call.dispatch == "invokeFnValue") {
        for (receiver in call.receiver) invokesByFunction.getOrPut(receiver) { ArrayList() } += call
      } else if (call.dispatch == "virtual" && hierarchy.isSamMethod(call.target)) {
        for (receiver in call.receiver) samCallsByReceiver.getOrPut(receiver) { ArrayList() } += call
      }
      if (call.id in unmodelled) {
        for (arg in argsByCall[call.id].orEmpty().sortedBy { it.node }) {
          unmodelledByArgument.getOrPut(arg.node) { ArrayList() } += call.id
        }
      }
    }
  }

  private fun arrive(location: String, value: Value, arrival: Arrival) {
    val values = reach.getOrPut(location) { LinkedHashMap() }
    if (value in values) return
    values[value] = arrival
    work += location to value
    for (call in invokesByFunction[location].orEmpty()) bind(call, value, location, hasReceiverArg = true)
    for (call in samCallsByReceiver[location].orEmpty()) {
      if (decls[value.sym]?.kind == "lambda") bind(call, value, location, hasReceiverArg = false)
    }
    for (call in unmodelledByArgument[location].orEmpty()) {
      val caller = callsById.getValue(call).callerDecl
      if (value.sym in decls) callEdges += CallEdgeFact(call, caller, value.sym, "assumedInvoke")
    }
  }

  private val callsById: Map<String, CallFact> by lazy { calls.associateBy { it.id } }

  /** A function value reached an invoke: its arguments flow to the value's parameters. */
  private fun bind(call: CallFact, value: Value, location: String, hasReceiverArg: Boolean) {
    val key = call.id to value
    if (key in fnValues) return
    fnValues[key] = FnValueFact(call.id, value.sym, witness(location, value))
    val decl = decls[value.sym] ?: return
    if (decl.kind == "prop") {
      call.result?.let { addEdge(FlowFact(value.sym, it, "invokeReturn", call.site()), derived = true) }
      return
    }
    callEdges += CallEdgeFact(call.id, call.callerDecl, value.sym, "fnValue")
    val targets = buildList {
      if (hasReceiverArg) {
        val takesReceiver = decl.kind == "lambda" || !value.bound
        if (takesReceiver && "member" in decl.modifiers) add(value.sym + THIS)
        if (takesReceiver && "receiver" in decl.modifiers) add(value.sym + RECEIVER)
      }
      addAll(parameters[value.sym].orEmpty())
    }
    for (arg in argsByCall[call.id].orEmpty().sortedWith(compareBy({ it.index }, { it.node }))) {
      val target = targets.getOrNull(arg.index) ?: continue
      addEdge(FlowFact(arg.node, target, "invokeArg", call.site()), derived = true)
    }
    call.result?.let {
      addEdge(FlowFact(value.sym + RETURN, it, "invokeReturn", call.site()), derived = true)
    }
  }

  private fun witness(location: String, value: Value): List<FlowFact> {
    val path = ArrayList<FlowFact>()
    var current = location
    while (true) {
      val edge = reach[current]?.get(value)?.edge ?: break
      path += edge
      current = edge.from
    }
    return path.reversed()
  }

  private fun addEdge(edge: FlowFact, derived: Boolean) {
    if (!knownEdges.add(edge)) return
    edges.getOrPut(edge.from) { ArrayList() } += edge
    if (derived) derivedFlows += edge
    for (value in reach[edge.from]?.keys.orEmpty().toList()) arrive(edge.to, value, Arrival(edge))
  }

  /** What a caller passes to a member reaches every override of it, and likewise for `actual`. */
  private fun overrideFlows() {
    val pairs =
      facts.overrides.map { it.sym to it.overridden } + facts.actuals.map { it.actual to it.expect }
    for ((sub, sup) in pairs.sortedWith(compareBy({ it.first }, { it.second }))) {
      val subDecl = decls[sub] ?: continue
      val at = "${subDecl.file}:${subDecl.span}"
      if (subDecl.kind == "prop") {
        addEdge(FlowFact(sub, sup, "override", at), derived = true)
        if ("var" in decls[sup]?.modifiers.orEmpty()) {
          addEdge(FlowFact(sup, sub, "override", at), derived = true)
        }
        continue
      }
      if (subDecl.kind != "fun" && subDecl.kind != "ctor") continue
      val subParameters = parameters[sub].orEmpty()
      parameters[sup].orEmpty().forEachIndexed { index, parameter ->
        subParameters.getOrNull(index)?.let {
          addEdge(FlowFact(parameter, it, "override", at), derived = true)
        }
      }
      addEdge(FlowFact(sub + RETURN, sup + RETURN, "override", at), derived = true)
      addEdge(FlowFact(sup + THIS, sub + THIS, "override", at), derived = true)
      addEdge(FlowFact(sup + RECEIVER, sub + RECEIVER, "override", at), derived = true)
    }
  }

  private fun staticCallEdges() {
    val actuals = facts.actuals.groupBy({ it.expect }, { it.actual })
    for (call in calls) {
      when (call.dispatch) {
        "invokeFnValue" -> {}
        "virtual" ->
          for (callee in hierarchy.implementations(call.target, call.receiverType)) {
            callEdges += CallEdgeFact(call.id, call.callerDecl, callee, "cha")
          }
        else -> {
          val actual = actuals[call.target].orEmpty().filter { it in decls }
          val via = if (call.dispatch == "static") "static" else call.dispatch
          when {
            actual.isNotEmpty() ->
              actual.forEach { callEdges += CallEdgeFact(call.id, call.callerDecl, it, "actual") }
            call.target in decls ->
              callEdges += CallEdgeFact(call.id, call.callerDecl, call.target, via)
          }
        }
      }
    }
    for (node in facts.nodes) {
      val target = node.target ?: continue
      if (node.kind == "objectCreation" && "anonymous" in decls[target]?.modifiers.orEmpty()) {
        callEdges += CallEdgeFact(node.id, node.enclosingDecl, target, "init")
      }
    }
  }

  private fun CallFact.site(): String = id.substringBeforeLast(':')

  private companion object {
    val flowOrder = compareBy<FlowFact>({ it.from }, { it.to }, { it.kind }, { it.at })
  }
}

/** Class-hierarchy analysis over `supertype` and `override`. */
private class Hierarchy(facts: Facts, private val decls: Map<String, DeclFact>) {
  private val supers: Map<String, List<SupertypeFact>> =
    facts.supertypes.sortedWith(compareBy({ it.cls }, { it.sup })).groupBy { it.cls }
  private val subs: Map<String, List<String>> =
    facts.supertypes.groupBy({ it.sup }, { it.cls }).mapValues { it.value.distinct().sorted() }
  private val overriders: Map<String, List<String>> =
    facts.overrides.groupBy({ it.overridden }, { it.sym }).mapValues { it.value.distinct().sorted() }
  private val cache = HashMap<Pair<String, String?>, List<String>>()

  fun isSamMethod(member: String): Boolean {
    val decl = decls[member] ?: return false
    return "abstract" in decl.modifiers && "fun" in decls[decl.owner]?.modifiers.orEmpty()
  }

  /** The declarations a virtual call of [target] may run when its receiver is a [receiverType]. */
  fun implementations(target: String, receiverType: String?): List<String> =
    cache.getOrPut(target to receiverType) {
      val accessor = ACCESSORS.firstOrNull { target.endsWith(it) }.orEmpty()
      val member = target.removeSuffix(accessor)
      val found = LinkedHashSet<String>()
      collect(member, receiverType, found, HashSet())
      found.map { it + accessor }.filter { it in decls }.sorted()
    }

  private fun collect(
    member: String,
    receiverType: String?,
    found: MutableSet<String>,
    visiting: MutableSet<Pair<String, String?>>,
  ) {
    if (!visiting.add(member to receiverType)) return
    val family = closure(member, overriders)
    val start = receiverType?.takeIf { it in decls } ?: decls[member]?.owner?.takeIf { it in decls }
    if (start == null) {
      found += family.filter(::isConcrete)
      return
    }
    val memberOf = family.mapNotNull { m -> decls[m]?.owner?.let { it to m } }.toMap()
    for (cls in closure(start, subs)) {
      if (!isInstantiable(cls)) continue
      var implementation: String? = null
      val delegates = ArrayList<SupertypeFact>()
      val queue = ArrayDeque(listOf(cls))
      val seen = HashSet<String>()
      while (queue.isNotEmpty() && implementation == null) {
        val current = queue.removeFirst()
        if (!seen.add(current)) continue
        memberOf[current]?.takeIf(::isConcrete)?.let { implementation = it }
        for (supertype in supers[current].orEmpty()) {
          if (supertype.viaDelegation) delegates += supertype
          queue += supertype.sup
        }
      }
      val found1 = implementation
      if (found1 != null) {
        found += found1
        continue
      }
      // Nothing in the class implements the member, so a `by` delegate must.
      val owner = decls[member]?.owner
      for (delegate in delegates) {
        if (owner != null && owner !in closure(delegate.sup, superIds)) continue
        collect(member, delegate.delegateType, found, visiting)
      }
    }
  }

  private val superIds: Map<String, List<String>> by lazy { supers.mapValues { e -> e.value.map { it.sup } } }

  private fun isConcrete(member: String): Boolean {
    val decl = decls[member] ?: return false
    return "abstract" !in decl.modifiers && "expect" !in decl.modifiers
  }

  private fun isInstantiable(cls: String): Boolean {
    val decl = decls[cls] ?: return false
    if (decl.kind == "interface") return false
    return "abstract" !in decl.modifiers && "sealed" !in decl.modifiers
  }

  private fun closure(start: String, next: Map<String, List<String>>): Set<String> {
    val seen = LinkedHashSet<String>()
    val queue = ArrayDeque(listOf(start))
    while (queue.isNotEmpty()) {
      val current = queue.removeFirst()
      if (seen.add(current)) queue += next[current].orEmpty()
    }
    return seen
  }
}
