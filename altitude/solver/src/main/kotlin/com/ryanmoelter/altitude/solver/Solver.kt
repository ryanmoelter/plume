package com.ryanmoelter.altitude.solver

import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.CellAccessFact
import com.ryanmoelter.altitude.facts.CellFact
import com.ryanmoelter.altitude.facts.LambdaCallFact
import com.ryanmoelter.altitude.facts.UNRESOLVED_TARGET
import com.ryanmoelter.altitude.model.ArgSelector
import com.ryanmoelter.altitude.model.DispatchReceiverBase
import com.ryanmoelter.altitude.model.LambdaParam
import com.ryanmoelter.altitude.model.LambdaPart
import com.ryanmoelter.altitude.model.LambdaReceiver
import com.ryanmoelter.altitude.model.LambdaReturn
import com.ryanmoelter.altitude.model.ModelEntry
import com.ryanmoelter.altitude.model.Models
import com.ryanmoelter.altitude.model.Port
import com.ryanmoelter.altitude.model.ReceiverBase
import com.ryanmoelter.altitude.model.ResultBase
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
private const val DELEGATE = "#<delegate>"
private val ACCESSORS = listOf("#<get>", "#<set>")

/** The suffix of the location that holds what a container or stream object contains. */
const val ELEMENT = "#<elem>"

/** Edge kinds that derive one value from another; no function value or object moves along them. */
val DERIVING_KINDS = setOf("memberOf", "contentOf", "partOf")

private val NOT_OBJECTS = setOf("literal", "lambdaExpr", "callableRef")

/**
 * Derives which function values reach each invoke, which declarations each call can run, and how
 * values move through the library calls that `altitude/models` describes.
 *
 * The analysis is flow-insensitive and field-based: a property, a parameter and a local are each
 * one location whatever object or call they belong to. Function values and container objects move
 * along `flow` edges until nothing changes. Reaching an invoke adds the edges that bind its
 * arguments and result; reaching a port of a modelled call adds the model's `summary` edges.
 */
fun solve(facts: Facts, models: Models = Models.bundled()): Derived =
  withoutContexts(Solver(expand(facts).facts, models).run())

private sealed interface Value

/** A lambda, or a function, constructor or property named by a callable reference. */
private data class Fn(val sym: String, val bound: Boolean) : Value

/** The object that first appears at [root]; its content is the location `root#<elem>`. */
private data class Obj(val root: String) : Value

/** How a value first got to a location: over [edge], or as the node that creates it. */
private class Arrival(val edge: FlowFact?) {
  var processed = false
}

private class Access(val slot: String, val call: CallFact, val op: String)

private class Triggered(val slot: String, val lambda: String, val op: String)

private class Solver(private val facts: Facts, private val models: Models) {
  private val decls: Map<String, DeclFact> =
    facts.decls.sortedBy { it.sym }.groupBy { it.sym }.mapValues { it.value.first() }
  private val parameters: Map<String, List<String>> =
    facts.decls
      .filter { it.kind == "param" && it.owner != null && it.index != null }
      .groupBy { it.owner!! }
      .mapValues { (_, all) -> all.sortedBy { it.index }.map { it.sym }.distinct() }
  private val nodeKinds: Map<String, String> = facts.nodes.associate { it.id to it.kind }
  private val calls = facts.calls.sortedBy { it.id }
  private val callsById: Map<String, CallFact> = calls.associateBy { it.id }
  private val argsByCall: Map<String, List<ArgFact>> =
    facts.args.groupBy { it.call }.mapValues { (_, args) ->
      args.sortedWith(compareBy({ it.index }, { it.node }, { it.param }))
    }

  private val edges = HashMap<String, MutableList<FlowFact>>()
  private val incoming = HashMap<String, MutableList<String>>()
  private val knownEdges = HashSet<FlowFact>()
  private val derivedFlows = ArrayList<FlowFact>()
  private val reach = HashMap<String, LinkedHashMap<Value, Arrival>>()
  private val work = ArrayDeque<Pair<String, Value>>()

  private val invokesByFunction = HashMap<String, MutableList<CallFact>>()
  private val samCallsByReceiver = HashMap<String, MutableList<CallFact>>()
  private val unmodelledByArgument = HashMap<String, MutableList<String>>()
  private val fnListeners = HashMap<String, MutableList<(Fn) -> Unit>>()
  private val objListeners = LinkedHashMap<String, MutableList<(Obj) -> Unit>>()
  private val roots = HashSet<String>()

  private val fnValues = LinkedHashMap<Pair<String, Fn>, FnValueFact>()
  private val callEdges = LinkedHashSet<CallEdgeFact>()
  private val unmodelled = LinkedHashSet<LambdaCallFact>()
  private val cellCreators = LinkedHashMap<String, String>()
  private val writes = ArrayList<Access>()
  private val reads = ArrayList<Access>()
  private val triggered = ArrayList<Triggered>()
  private val pipes = LinkedHashSet<Pair<String, String>>()

  private val hierarchy = Hierarchy(facts, decls)

  fun run(): Derived {
    for (flow in facts.flows.sortedWith(flowOrder)) addEdge(flow, derived = false)
    overrideFlows()
    indexCalls()
    for (node in facts.nodes.sortedBy { it.id }) {
      val target = node.target ?: continue
      when (node.kind) {
        "lambdaExpr" -> arrive(node.id, Fn(target, bound = true), Arrival(null))
        "callableRef" -> arrive(node.id, Fn(target, node.bound), Arrival(null))
      }
    }
    do {
      while (work.isNotEmpty()) {
        val (location, value) = work.removeFirst()
        arrived(location, value)
        for (edge in edges[location].orEmpty().toList()) arrive(edge.to, value, Arrival(edge))
      }
    } while (createObjects())
    staticCallEdges()
    val cells = cells()
    cellCallEdges()
    val reaching = fnValues.keys.groupBy({ it.first }, { it.second.sym })
    val fanOuts =
      calls
        .filter { it.dispatch == "invokeFnValue" }
        .map { FanOutFact(it.id, reaching[it.id].orEmpty().distinct().size) }
    return Derived(
      flows = derivedFlows,
      fnValues = fnValues.values.toList(),
      callEdges = callEdges.toList(),
      fanOuts = fanOuts,
      unmodelledLambdaCalls = unmodelled.toList(),
      cells = cells.values.toList(),
      cellWrites = accesses(writes, cells),
      cellReads = accesses(reads, cells),
    )
  }

  private fun indexCalls() {
    val lambdaCalls = facts.libraryLambdaCalls.associateBy { it.call }
    for (call in calls) {
      if (call.dispatch == "invokeFnValue") {
        for (receiver in call.receiver) invokesByFunction.getOrPut(receiver) { ArrayList() } += call
        continue
      }
      if (call.dispatch == "virtual" && hierarchy.isSamMethod(call.target)) {
        for (receiver in call.receiver) samCallsByReceiver.getOrPut(receiver) { ArrayList() } += call
      }
      val entry =
        if (call.targetInSource || call.target == UNRESOLVED_TARGET) null else models.match(call.target)
      val lambdaCall = lambdaCalls[call.id]
      if (entry != null) {
        applyModel(call, entry, takesFunction = lambdaCall != null)
      } else if (lambdaCall != null) {
        unmodelled += lambdaCall
        for (arg in argsByCall[call.id].orEmpty()) {
          unmodelledByArgument.getOrPut(arg.node) { ArrayList() } += call.id
        }
      }
    }
  }

  // Models

  private fun applyModel(call: CallFact, entry: ModelEntry, takesFunction: Boolean) {
    val rule = entry.ruleId
    val at = call.site()
    for (spec in entry.flows) {
      resolve(call, spec.from, rule, source = true) { from ->
        resolve(call, spec.to, rule, source = false) { to ->
          addEdge(FlowFact(from, to, "summary", at, rule), derived = true)
        }
      }
    }
    for (spec in entry.triggers) {
      resolve(call, spec.from, rule, source = false) { from ->
        resolve(call, spec.to, rule, source = false) { to -> pipes += from to to }
      }
    }
    for (spec in entry.writes) resolve(call, spec.port, rule, false) { writes += Access(it, call, spec.op) }
    for (spec in entry.reads) resolve(call, spec.port, rule, false) { reads += Access(it, call, spec.op) }
    val result = call.result
    if (entry.cell != null && result != null) {
      cellCreators[result] = entry.cell
      onObj(result) {}
    }
    for (arg in argsByCall[call.id].orEmpty()) {
      val name = arg.param.substringAfterLast('#')
      val spec =
        entry.invokes.firstOrNull {
          it.lambda.matches(arg.index, name) &&
            (it.whenAnnotated == null || it.whenAnnotated in arg.typeAnnotations)
        }
      val storedAsValue =
        entry.flows.any {
          it.from.lambda == null && !it.from.element && (it.from.base as? ArgSelector)?.matches(arg.index, name) == true
        }
      if (spec == null && (storedAsValue || !takesFunction)) continue
      onFn(arg.node) { fn ->
        val decl = decls[fn.sym] ?: return@onFn
        if (decl.kind == "prop") return@onFn
        if (spec == null) {
          callEdges += CallEdgeFact(call.id, call.callerDecl, fn.sym, "assumedInvoke")
          unmodelled += LambdaCallFact(call.id, call.target)
          return@onFn
        }
        callEdges +=
          CallEdgeFact(call.id, call.callerDecl, fn.sym, "invoke", ruleId = rule, role = spec.role, invoker = call.target)
        for (on in spec.on) {
          resolve(call, on, rule, source = false) { triggered += Triggered(it, fn.sym, entry.id) }
        }
      }
    }
  }

  /** Calls [use] with every location [port] names at [call], now and as values arrive. */
  private fun resolve(call: CallFact, port: Port, rule: String, source: Boolean, use: (String) -> Unit) {
    fun element(location: String) {
      if (!port.element) return use(location)
      onObj(location) { obj ->
        val slot = obj.root + ELEMENT
        if (source) addEdge(FlowFact(location, slot, "contentOf", call.site(), rule), derived = true)
        use(slot)
      }
    }
    val bases =
      when (val base = port.base) {
        ReceiverBase -> call.extReceiver.ifEmpty { call.receiver }
        DispatchReceiverBase -> call.receiver
        ResultBase -> listOfNotNull(call.result)
        is ArgSelector ->
          argsByCall[call.id].orEmpty().filter { base.matches(it.index, it.param.substringAfterLast('#')) }.map { it.node }
      }
    val part = port.lambda
    for (base in bases.distinct()) {
      if (part == null) element(base) else onFn(base) { fn -> lambdaLocations(fn, part).forEach(::element) }
    }
  }

  private fun lambdaLocations(fn: Fn, part: LambdaPart): List<String> {
    val decl = decls[fn.sym] ?: return emptyList()
    if (decl.kind == "prop") {
      // `Expense::date` as a selector returns what the property holds.
      return if (part == LambdaReturn) listOf(fn.sym) else emptyList()
    }
    if (part == LambdaReturn) return listOf(fn.sym + RETURN)
    val own = parameters[fn.sym].orEmpty()
    if (decl.kind == "lambda") {
      return when (part) {
        LambdaReceiver -> if ("receiver" in decl.modifiers) listOf(fn.sym + RECEIVER) else emptyList()
        is LambdaParam -> if (part.index == null) own else listOfNotNull(own.getOrNull(part.index))
        else -> emptyList()
      }
    }
    val positions = receiverTargets(decl, fn) + own
    return when (part) {
      LambdaReceiver -> listOfNotNull(positions.firstOrNull())
      is LambdaParam -> if (part.index == null) positions else listOfNotNull(positions.getOrNull(part.index))
      else -> emptyList()
    }
  }

  private fun receiverTargets(decl: DeclFact, fn: Fn): List<String> = buildList {
    val takesReceiver = decl.kind == "lambda" || !fn.bound
    if (takesReceiver && "member" in decl.modifiers) add(fn.sym + THIS)
    if (takesReceiver && "receiver" in decl.modifiers) add(fn.sym + RECEIVER)
  }

  private fun onFn(location: String, listener: (Fn) -> Unit) {
    fnListeners.getOrPut(location) { ArrayList() } += listener
    for ((value, arrival) in reach[location].orEmpty().entries.toList()) {
      if (value is Fn && arrival.processed) listener(value)
    }
  }

  private fun onObj(location: String, listener: (Obj) -> Unit) {
    objListeners.getOrPut(location) { ArrayList() } += listener
    for ((value, arrival) in reach[location].orEmpty().entries.toList()) {
      if (value is Obj && arrival.processed) listener(value)
    }
  }

  /**
   * An element port needs an object to hold the element. Every location upstream of one that
   * nothing flows into is where such an object first appears: the result of a library call, a
   * parameter no caller in the sources fills, a property set outside them.
   */
  private fun createObjects(): Boolean {
    val seen = HashSet<String>()
    val stack = ArrayDeque(objListeners.keys)
    var created = false
    while (stack.isNotEmpty()) {
      val location = stack.removeLast()
      if (!seen.add(location)) continue
      val sources = incoming[location]
      if (sources != null) {
        stack += sources
      } else if (nodeKinds[location] !in NOT_OBJECTS && !isNestedElement(location) && roots.add(location)) {
        arrive(location, Obj(location), Arrival(null))
        created = true
      }
    }
    return created
  }

  /**
   * A container's element may itself be a container that nothing in the sources fills, but the
   * nesting stops there: one level deeper would repeat without end on `xs = xs.filter { }`.
   */
  private fun isNestedElement(location: String): Boolean = location.endsWith(ELEMENT + ELEMENT)

  private fun cells(): Map<String, CellFact> {
    val cells = LinkedHashMap<String, CellFact>()
    for ((root, mechanism) in cellCreators) {
      if (root in roots) cells[root] = CellFact(root, holder(root), mechanism)
    }
    return cells
  }

  /** The nearest property or local the object created at [root] flows into. */
  private fun holder(root: String): String? {
    var level = listOf(root)
    val seen = HashSet(level)
    repeat(8) {
      val next = level.flatMap { edges[it].orEmpty() }.map { it.to }
      val holders = next.map { it.removeSuffix(DELEGATE) }.filter { decls[it]?.kind in HOLDERS }
      holders.minOrNull()?.let { return it }
      level = next.filter { ELEMENT !in it && seen.add(it) }.distinct()
    }
    return null
  }

  private fun accesses(all: List<Access>, cells: Map<String, CellFact>): List<CellAccessFact> =
    all.mapNotNull { access ->
      val cell = access.slot.removeSuffix(ELEMENT)
      if (cell in cells) CellAccessFact(cell, access.call.id, access.op) else null
    }

  /**
   * Writing a stream's element runs the lambdas a model invokes `on` that element, and on the
   * element of every stream derived from it by an operator.
   */
  private fun cellCallEdges() {
    val downstream = HashMap<String, MutableList<String>>()
    for ((from, to) in pipes) downstream.getOrPut(from) { ArrayList() } += to
    for (flow in derivedFlows) {
      if (flow.kind == "summary" && flow.from.endsWith(ELEMENT) && flow.to.endsWith(ELEMENT)) {
        downstream.getOrPut(flow.from) { ArrayList() } += flow.to
      }
    }
    val readers = triggered.groupBy { it.slot }
    val distances = HashMap<String, Map<String, Int>>()
    for (write in writes) {
      if (write.op == "initial") continue
      val reached =
        distances.getOrPut(write.slot) {
          val distance = LinkedHashMap<String, Int>()
          distance[write.slot] = 0
          val queue = ArrayDeque(listOf(write.slot))
          while (queue.isNotEmpty()) {
            val current = queue.removeFirst()
            for (next in downstream[current].orEmpty()) {
              if (next !in distance) {
                distance[next] = distance.getValue(current) + 1
                queue += next
              }
            }
          }
          distance
        }
      for ((slot, through) in reached) {
        for (reader in readers[slot].orEmpty()) {
          callEdges +=
            CallEdgeFact(
              call = write.call.id,
              caller = write.call.callerDecl,
              callee = reader.lambda,
              via = "cell",
              cell = write.slot.removeSuffix(ELEMENT),
              op = "${write.op} → ${reader.op}",
              through = through,
            )
        }
      }
    }
  }

  // Propagation

  private fun arrive(location: String, value: Value, arrival: Arrival) {
    val values = reach.getOrPut(location) { LinkedHashMap() }
    if (value in values) return
    values[value] = arrival
    work += location to value
  }

  private fun arrived(location: String, value: Value) {
    reach.getValue(location).getValue(value).processed = true
    when (value) {
      is Obj -> for (listener in objListeners[location].orEmpty().toList()) listener(value)
      is Fn -> {
        for (call in invokesByFunction[location].orEmpty()) bind(call, value, location, hasReceiverArg = true)
        for (call in samCallsByReceiver[location].orEmpty()) {
          if (decls[value.sym]?.kind == "lambda") bind(call, value, location, hasReceiverArg = false)
        }
        for (call in unmodelledByArgument[location].orEmpty()) {
          val caller = callsById.getValue(call).callerDecl
          if (value.sym in decls) callEdges += CallEdgeFact(call, caller, value.sym, "assumedInvoke")
        }
        for (listener in fnListeners[location].orEmpty().toList()) listener(value)
      }
    }
  }

  /** A function value reached an invoke: its arguments flow to the value's parameters. */
  private fun bind(call: CallFact, value: Fn, location: String, hasReceiverArg: Boolean) {
    val key = call.id to value
    if (key in fnValues) return
    fnValues[key] = FnValueFact(call.id, value.sym, witness(location, value))
    val decl = decls[value.sym] ?: return
    if (decl.kind == "prop") {
      call.result?.let { addEdge(FlowFact(value.sym, it, "invokeReturn", call.site()), derived = true) }
      return
    }
    callEdges += CallEdgeFact(call.id, call.callerDecl, value.sym, "fnValue")
    val targets = (if (hasReceiverArg) receiverTargets(decl, value) else emptyList()) + parameters[value.sym].orEmpty()
    for (arg in argsByCall[call.id].orEmpty()) {
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
    if (derived) derivedFlows += edge
    if (edge.kind in DERIVING_KINDS) return
    edges.getOrPut(edge.from) { ArrayList() } += edge
    incoming.getOrPut(edge.to) { ArrayList() } += edge.from
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
    val HOLDERS = setOf("prop", "local")
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
