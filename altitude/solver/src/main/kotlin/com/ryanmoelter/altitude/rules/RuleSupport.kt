package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact

/** The parts of a callable ID such as `fun:a/b/Outer.Inner.name@recv(params)`. */
internal class CallableId(
  /** `fun`, `ctor` or `prop`. */
  val kind: String,
  val pkg: String,
  /** The enclosing classes, outermost first; for a constructor they end with its own class. */
  val owners: List<String>,
  val name: String,
) {
  val ownerClass: String?
    get() = if (owners.isEmpty()) null else "class:$pkg/${owners.joinToString(".")}"

  /** `Owner.name` for a member, the class name for a constructor, the bare name otherwise. */
  val qualifiedName: String
    get() = if (kind == "ctor") owners.joinToString(".") else (owners + name).joinToString(".")

  /** `a.b.Outer.name`, without a trailing `invoke`. */
  val dottedName: String
    get() {
      val parts = if (kind == "ctor") owners else owners + name
      val named = if (parts.size > 1 && parts.last() == "invoke") parts.dropLast(1) else parts
      return (pkg.split('/') + named).filter { it.isNotEmpty() }.joinToString(".")
    }

  companion object {
    fun parse(id: String): CallableId? {
      val kind = id.substringBefore(':', "")
      if (kind !in setOf("fun", "ctor", "prop")) return null
      val head = id.substringAfter(':').substringBefore('@').substringBefore('(').substringBefore('#')
      val pkg = head.substringBeforeLast('/', "")
      val segments = head.substringAfterLast('/').split('.')
      return if (kind == "ctor") CallableId(kind, pkg, segments, segments.last())
      else CallableId(kind, pkg, segments.dropLast(1), segments.last())
    }
  }
}

/** One value of a collection argument; [unsure] says why it may be absent at run time. */
internal class Element(val node: String, val unsure: String? = null)

internal fun FactIndex.argNodes(call: CallFact, param: String): List<String> =
  args[call.id].orEmpty().filter { it.param.substringAfterLast('#') == param }.map { it.node }

internal fun FactIndex.argNodes(call: CallFact, index: Int): List<String> =
  args[call.id].orEmpty().filter { it.index == index }.map { it.node }

/** A string literal's contents; a template keeps its `$` parts as written. */
internal fun FactIndex.literalString(node: String): String? {
  val text = nodes[node]?.takeIf { it.kind == "literal" }?.text ?: return null
  return if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) text.substring(1, text.length - 1) else null
}

/** A string literal, or a reference to a property that a string literal initializes. */
internal fun FactIndex.constString(node: String): String? {
  literalString(node)?.let { return it }
  val target = nodes[node]?.target ?: return null
  return flowsInto[target].orEmpty().firstNotNullOfOrNull { literalString(it.from) }
}

/** The class a rendered type names, without type arguments or nullability. */
internal fun dottedClassOf(type: String?): String? =
  type?.substringBefore('<')?.removeSuffix("?")?.takeIf { it.isNotEmpty() && ' ' !in it }

/**
 * The values a collection expression holds: the arguments of `listOf`, both sides of `+`, and each
 * branch of a conditional, which arrives as several nodes for one argument.
 */
internal fun FactIndex.elements(node: String, depth: Int = 0): List<Element> {
  val call = callsByResult[node]
  val id = call?.let { CallableId.parse(it.target) }
  if (call == null || id == null || id.pkg != "kotlin/collections" || depth > 20) return listOf(Element(node))
  fun nested(nodes: List<String>, why: String?): List<Element> {
    val conditional = why ?: if (nodes.size > 1) "conditional" else null
    return nodes.flatMap { inner -> elements(inner, depth + 1).map { Element(it.node, it.unsure ?: conditional) } }
  }
  val arguments = args[call.id].orEmpty()
  return when (id.name) {
    "emptyList", "emptySet" -> emptyList()
    "listOf", "setOf", "mutableListOf", "listOfNotNull", "setOfNotNull" ->
      arguments.map { arg ->
        val why =
          when {
            id.name.endsWith("NotNull") -> id.name
            arg.form == "spread" -> "spread"
            else -> null
          }
        Element(arg.node, why)
      }
    "plus" -> nested(call.extReceiver + call.receiver, null) + arguments.groupBy { it.index }.values.flatMap { same -> nested(same.map { it.node }, null) }
    else -> listOf(Element(node))
  }
}

internal fun FactIndex.isPublic(decl: DeclFact): Boolean =
  decl.modifiers.none { it == "private" || it == "protected" || it == "internal" }

internal fun FactIndex.memberFunctions(cls: String): List<DeclFact> =
  members[cls].orEmpty().filter { it.kind == "fun" }
