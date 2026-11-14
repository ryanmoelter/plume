package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.facts.UNRESOLVED_TARGET

private val CALLABLE_KINDS = setOf("fun", "ctor", "lambda", "getter", "setter")
private val CLASS_KINDS = setOf("class", "interface", "object", "enumEntry")
private val PSEUDO = Regex("""#<[^>]*>$""")
private val POSITIONAL = Regex("""^(.*):(\d+):(\d+)-(\d+):(\d+):(\w+)$""")
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

  /** Calls into code outside the analysed sources, by the declaration that makes them. */
  val boundaryCalls: Map<String, List<CallFact>> =
    facts.calls
      .filter { !it.targetInSource && it.target != UNRESOLVED_TARGET && it.dispatch != "invokeFnValue" }
      .groupBy { it.callerDecl }
      .mapValues { it.value.sortedWith(compareBy({ Site.of(it.id) }, { it.id })) }

  fun isCallable(sym: String): Boolean = decls[sym]?.kind in CALLABLE_KINDS

  /** `Owner.name` without parameters; what a selector matches. */
  fun qualifiedName(sym: String): String {
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
      "lambda" -> "lambda@${shortSite(decl)}"
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
    val decl = decls[sym]
    if (decl == null) {
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

  private val parameters: Map<String, List<DeclFact>> =
    facts.decls.filter { it.kind == "param" && it.owner != null }.groupBy { it.owner!! }

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

  private fun matches(name: String, selector: String): Boolean =
    name == selector || name.endsWith(".$selector")
}

class Selection(val selector: String, val decls: List<String>, val library: List<String>) {
  val isUnique: Boolean
    get() = decls.size + library.size == 1
}
