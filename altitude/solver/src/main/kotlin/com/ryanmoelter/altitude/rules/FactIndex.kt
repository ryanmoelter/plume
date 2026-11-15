package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.facts.SupertypeFact

private val CLASS_KINDS = setOf("class", "interface", "object")
private val SPAN_LINE = Regex("""^(\d+):""")
private val CALL_LINE = Regex("""^.*?:(\d+):\d+-\d+:\d+(?::\w+)?$""")

/** The extracted facts, indexed the way the rules read them. Every list is in a stable order. */
class FactIndex(val facts: Facts) {
  val decls: Map<String, DeclFact> =
    facts.decls.sortedBy { it.sym }.groupBy { it.sym }.mapValues { it.value.first() }

  val classes: List<DeclFact> = decls.values.filter { it.kind in CLASS_KINDS }

  /** Members and nested declarations by owner, in ID order. */
  val members: Map<String, List<DeclFact>> =
    decls.values.filter { it.owner != null }.groupBy { it.owner!! }

  val annotations: Map<String, List<AnnotationFact>> =
    facts.annotations.sortedWith(compareBy({ it.sym }, { it.annFq }, { it.args.toString() })).groupBy { it.sym }

  val supertypes: Map<String, List<SupertypeFact>> =
    facts.supertypes.sortedWith(compareBy({ it.cls }, { it.sup })).groupBy { it.cls }

  val subtypes: Map<String, List<String>> =
    facts.supertypes.sortedWith(compareBy({ it.sup }, { it.cls })).groupBy({ it.sup }, { it.cls })

  val overrides: Map<String, List<String>> =
    facts.overrides.sortedWith(compareBy({ it.sym }, { it.overridden })).groupBy({ it.sym }, { it.overridden })

  val overriddenBy: Map<String, List<String>> =
    facts.overrides.sortedWith(compareBy({ it.overridden }, { it.sym })).groupBy({ it.overridden }, { it.sym })

  val nodes: Map<String, NodeFact> = facts.nodes.associateBy { it.id }

  val calls: List<CallFact> = facts.calls.sortedBy { it.id }

  val callsById: Map<String, CallFact> = calls.associateBy { it.id }

  /** The call whose value a `callResult` node holds. */
  val callsByResult: Map<String, CallFact> = calls.filter { it.result != null }.associateBy { it.result!! }

  val callsByCaller: Map<String, List<CallFact>> = calls.groupBy { it.callerDecl }

  val args: Map<String, List<ArgFact>> =
    facts.args.groupBy { it.call }.mapValues { (_, all) ->
      all.sortedWith(compareBy({ it.index }, { it.node }, { it.param }))
    }

  val flowsInto: Map<String, List<FlowFact>> =
    facts.flows.sortedWith(compareBy({ it.to }, { it.from }, { it.kind }, { it.at })).groupBy { it.to }

  val flowsFrom: Map<String, List<FlowFact>> =
    facts.flows.sortedWith(compareBy({ it.from }, { it.to }, { it.kind }, { it.at })).groupBy { it.from }

  /** A class ID by the dotted name a rendered type uses for it. */
  val classByDottedName: Map<String, String> =
    classes.associate { dotted(it.sym) to it.sym }

  private val parameterLists: Map<String, List<DeclFact>> =
    decls.values
      .filter { it.kind == "param" && it.owner != null && it.index != null }
      .groupBy { it.owner!! }
      .mapValues { (_, all) -> all.sortedBy { it.index } }

  fun parameters(owner: String): List<DeclFact> = parameterLists[owner].orEmpty()

  fun annotationsOf(sym: String): List<AnnotationFact> = annotations[sym].orEmpty()

  fun annotation(sym: String, annFq: String): AnnotationFact? =
    annotations[sym]?.firstOrNull { it.annFq == annFq }

  fun hasAnnotation(sym: String, annFq: String): Boolean = annotation(sym, annFq) != null

  fun has(decl: DeclFact, modifier: String): Boolean = modifier in decl.modifiers

  /** The class and every class it extends or implements, nearest first, each once. */
  fun supertypeClosure(cls: String): List<String> {
    val seen = LinkedHashSet<String>()
    val queue = ArrayDeque(listOf(cls))
    while (queue.isNotEmpty()) {
      val next = queue.removeFirst()
      if (!seen.add(next)) continue
      supertypes[next].orEmpty().forEach { queue += it.sup }
    }
    return seen.toList()
  }

  /** The class and every class below it, each once. */
  fun subtypeClosure(cls: String): List<String> {
    val seen = LinkedHashSet<String>()
    val queue = ArrayDeque(listOf(cls))
    while (queue.isNotEmpty()) {
      val next = queue.removeFirst()
      if (!seen.add(next)) continue
      subtypes[next].orEmpty().forEach { queue += it }
    }
    return seen.toList()
  }

  /** The first line of a declaration's span, which starts at its first annotation. */
  fun line(decl: DeclFact?): Int? =
    decl?.span?.let { SPAN_LINE.find(it)?.groupValues?.get(1)?.toInt() }

  /** The start line of a positional ID such as a call's. */
  fun lineOf(id: String): Int? = CALL_LINE.matchEntire(id)?.groupValues?.get(1)?.toInt()

  /** The file of a positional ID. */
  fun fileOf(id: String): String? =
    Regex("""^(.*?):\d+:\d+-\d+:\d+(?::\w+)?$""").matchEntire(id)?.groupValues?.get(1)

  /** The class, interface or object that holds a declaration, skipping callables. */
  fun enclosingClass(sym: String): String? {
    var current = decls[sym]?.owner
    while (current != null) {
      val decl = decls[current] ?: return null
      if (decl.kind in CLASS_KINDS) return decl.sym
      current = decl.owner
    }
    return null
  }

  /** The named function, constructor, accessor or property a lambda or local sits in. */
  fun enclosingNamed(sym: String): String? {
    var current: String? = sym
    while (current != null) {
      val decl = decls[current] ?: return null
      if (decl.kind in setOf("fun", "ctor", "getter", "setter", "prop") && !decl.sym.contains(":lambda")) {
        return decl.sym
      }
      current = decl.owner
    }
    return null
  }

  companion object {
    /** `class:a/b/Outer.Inner` as `a.b.Outer.Inner`. */
    fun dotted(classId: String): String = classId.substringAfter(':').replace('/', '.')

    /** `a/b/Ann` as `a.b.Ann`. */
    fun dottedName(slashed: String): String = slashed.replace('/', '.')
  }
}
