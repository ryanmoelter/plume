package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.solver.withoutContext
import java.util.SortedMap

internal val CLASS_KINDS = setOf("class", "interface", "object")
internal val NAMED_KINDS = setOf("class", "interface", "object", "enumEntry", "fun", "ctor", "prop", "getter", "setter")
internal val CALLABLE_KINDS = setOf("fun", "ctor", "getter", "setter")
internal const val ELEMENT = "#<elem>"
internal const val COMPOSABLE = "androidx/compose/runtime/Composable"
private const val TOP_PREFIX = "top:"
private val SPAN = Regex("""^(\d+):\d+-(\d+):\d+$""")

/** A class-level node: a top-level class, interface or object, or a file's top-level functions and properties. */
data class NodeInfo(
  val id: String,
  val kind: String,
  val name: String,
  val file: String,
  val line: Int,
  val loc: Int,
  val generated: Boolean,
  val module: String,
  val sourceSet: String,
  val pkg: String,
  val modifiers: List<String>,
)

/** Maps every declaration and location to its node, and nodes to the containers that hold them. */
class Units(val facts: Facts) {
  val decls: Map<String, DeclFact> = facts.decls.sortedBy { it.sym }.groupBy { it.sym }.mapValues { it.value.first() }
  val nodesById: Map<String, NodeFact> = facts.nodes.associateBy { it.id }
  val files: Map<String, FileFact> = facts.files.associateBy { it.path }
  private val cache = HashMap<String, String>()

  /** The node a declaration belongs to: its outermost named class, else its file's top level. */
  fun ofDecl(sym: String): String? =
    cache.getOrPut(sym) {
      var current = decls[sym] ?: return@getOrPut ""
      var guard = 0
      while (guard++ < 200) current = current.owner?.let { decls[it] } ?: break
      if (current.kind in CLASS_KINDS && "anonymous" !in current.modifiers) current.sym
      else current.file?.let { TOP_PREFIX + it } ?: ""
    }.ifEmpty { null }

  /** The node of a location: a declaration, a node, a part such as `#<ret>`, or a container's slot. */
  fun of(location: String): String? {
    var id = withoutContext(location)
    while (id.endsWith(ELEMENT)) id = id.removeSuffix(ELEMENT)
    nodesById[id]?.let { return ofDecl(it.enclosingDecl) }
    if (id in decls) return ofDecl(id)
    val part = id.lastIndexOf("#<")
    if (part > 0) return of(id.substring(0, part))
    return null
  }

  /** The dotted package of each file, from the qualified declarations it holds. */
  val packages: Map<String, String> =
    decls.values
      .filter { it.file != null && it.sym.substringBefore(':') in setOf("class", "fun", "prop", "ctor", "enumEntry") }
      .groupBy { it.file!! }
      .mapValues { (_, all) ->
        all.map { packageOf(it.sym) }.groupingBy { it }.eachCount().entries
          .sortedWith(compareBy({ -it.value }, { it.key })).first().key
      }

  val nodes: SortedMap<String, NodeInfo> = buildNodes()

  private fun buildNodes(): SortedMap<String, NodeInfo> {
    val out = sortedMapOf<String, NodeInfo>()
    val topLevel = HashMap<String, MutableList<DeclFact>>()
    for (decl in decls.values) {
      if (decl.kind !in NAMED_KINDS || "implicit" in decl.modifiers) continue
      val node = ofDecl(decl.sym) ?: continue
      if (node.startsWith(TOP_PREFIX) && decl.owner == "file:${decl.file}") topLevel.getOrPut(node) { ArrayList() } += decl
    }
    for (decl in decls.values) {
      if (decl.kind !in CLASS_KINDS || ofDecl(decl.sym) != decl.sym) continue
      val file = decl.file ?: continue
      val (start, end) = span(decl.span) ?: (0 to 0)
      out[decl.sym] = info(decl.sym, decl.kind, decl.name, file, start, end - start + 1, decl.modifiers)
    }
    for ((node, members) in topLevel) {
      val file = node.removePrefix(TOP_PREFIX)
      val spans = members.mapNotNull { span(it.span) }
      out[node] = info(node, "file", file.substringAfterLast('/'), file, spans.minOfOrNull { it.first } ?: 0, spans.sumOf { it.second - it.first + 1 }, emptyList())
    }
    return out
  }

  private fun info(id: String, kind: String, name: String, file: String, line: Int, loc: Int, modifiers: List<String>): NodeInfo {
    val fact = files[file]
    return NodeInfo(
      id = id,
      kind = kind,
      name = name,
      file = file,
      line = line,
      loc = loc,
      generated = fact?.generated ?: false,
      module = fact?.module ?: "?",
      sourceSet = fact?.sourceSet ?: "(none)",
      pkg = packages[file] ?: "",
      modifiers = modifiers.filter { it in KEPT_MODIFIERS }.sorted(),
    )
  }

  /** Named declarations per node, the node's class included. */
  val declCounts: Map<String, Int> =
    decls.values
      .filter { it.kind in NAMED_KINDS && "implicit" !in it.modifiers }
      .mapNotNull { ofDecl(it.sym) }
      .groupingBy { it }
      .eachCount()

  /** Every declaration of a node, lambdas and parameters included, in ID order. */
  val declsByNode: Map<String, List<DeclFact>> =
    decls.values.mapNotNull { d -> ofDecl(d.sym)?.let { it to d } }.groupBy({ it.first }, { it.second })

  companion object {
    private val KEPT_MODIFIERS = setOf("abstract", "data", "enum", "sealed", "value", "open", "annotation", "expect", "actual", "companion")

    fun span(span: String?): Pair<Int, Int>? =
      span?.let { SPAN.matchEntire(it) }?.destructured?.let { (a, b) -> a.toInt() to b.toInt() }

    fun packageOf(sym: String): String {
      val path = sym.substringAfter(':').substringBefore('(').substringBefore('@')
      return if ('/' in path) path.substringBeforeLast('/').replace('/', '.') else ""
    }
  }
}
