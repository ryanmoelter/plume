package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.CellFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.solver.withoutContext
import com.ryanmoelter.altitude.trace.Site

private val MEMBER_DECL_KINDS = setOf("fun", "ctor", "prop", "enumEntry")
private val ACCESSOR_KINDS = setOf("getter", "setter")
private val VISIBILITIES = listOf("private", "protected", "internal")
private val FLAG_MODIFIERS =
  setOf("suspend", "override", "inline", "operator", "abstract", "open", "expect", "actual", "noBody", "var", "lateinit", "const", "delegated", "ctorParam", "implicit")
private val TYPE_PACKAGE = Regex("""\b(?:[a-z_][A-Za-z0-9_]*\.)+(?=[A-Z])""")
private val POSITION = Regex("""^.*:(\d+):(\d+)-(\d+):(\d+)(?::\w+)?$""")
private val DECL_SPAN = Regex("""^(\d+):(\d+)-(\d+):(\d+)$""")
private const val SIGNATURE_LENGTH = 40

/** A member before the export numbers it. [span] is start line, start column, end line, end column. */
class MemberDraft(
  val id: String,
  val node: String,
  var kind: String,
  val name: String,
  val signature: String,
  val file: String?,
  val span: IntArray?,
  val visibility: String?,
  val flags: List<String>,
  /** The nested class the member is declared in, when it is not the node's own class. */
  val nestedClass: String?,
  /** The member a local cell lives in. */
  val parent: String?,
) {
  val cells = sortedSetOf<Int>()
  var lambdas = 0
  var size = 0
}

/**
 * The members of every node: its functions, constructors, written accessors and properties, plus
 * the cells it owns. Every declaration of a node belongs to exactly one member, or is the node's
 * class or a nested class. A lambda, parameter, local or local class belongs to the member around it.
 */
class Members(
  private val units: Units,
  private val composable: Set<String>,
  cellFacts: List<CellFact>,
) {
  private val decls = units.decls
  private val drafts = HashMap<String, MemberDraft>()
  private val structural = HashMap<String, Boolean>()
  private val implicitConstructors: Map<String, String> =
    decls.values.filter { it.kind == "ctor" && "implicit" in it.modifiers && it.owner != null }.associate { it.owner!! to it.sym }
  private val parameters: Map<String, List<DeclFact>> =
    decls.values.filter { it.kind == "param" && it.owner != null }.groupBy { it.owner!! }.mapValues { (_, p) -> p.sortedBy { it.index } }
  private var frozen = false
  private val cache = HashMap<String, String>()

  /** A named class of the node tree: not anonymous, and declared in a file or another such class. */
  fun isStructural(decl: DeclFact): Boolean =
    structural.getOrPut(decl.sym) {
      if (decl.kind !in CLASS_KINDS || "anonymous" in decl.modifiers) return@getOrPut false
      val owner = decl.owner?.let { decls[it] } ?: return@getOrPut true
      isStructural(owner)
    }

  private fun ownerIsStructural(decl: DeclFact): Boolean {
    val owner = decl.owner ?: return false
    if (owner.startsWith("file:")) return true
    return decls[owner]?.let(::isStructural) == true
  }

  init {
    for (decl in decls.values) if (decl.kind in MEMBER_DECL_KINDS && ownerIsStructural(decl)) add(decl, kindOf(decl))
    for (decl in decls.values) {
      if (decl.kind !in ACCESSOR_KINDS || "delegated" in decl.modifiers) continue
      if (decl.owner in drafts) add(decl, "function")
    }
    for ((index, cell) in cellFacts.withIndex()) {
      val holder = cell.sym
      val existing = holder?.let { drafts[it] }
      val draft =
        when {
          existing != null -> existing
          holder != null && decls[holder] != null -> addLocalCell(decls.getValue(holder))
          else -> addAnonymousCell(cell)
        } ?: continue
      draft.cells += index
      draft.kind = "cell"
    }
    cache.clear()
  }

  private fun kindOf(decl: DeclFact): String =
    when (decl.kind) {
      "fun" -> "function"
      "ctor" -> if ("implicit" in decl.modifiers) "initializer" else "constructor"
      else -> "property"
    }

  private fun nestedClassOf(decl: DeclFact): String? {
    var current = decl.owner?.let { decls[it] }
    while (current != null && !isStructural(current)) current = current.owner?.let { decls[it] }
    return current?.sym?.takeIf { units.ofDecl(it) != it }
  }

  private fun add(decl: DeclFact, kind: String, parent: String? = null): MemberDraft? {
    val node = units.ofDecl(decl.sym) ?: return null
    val flags = sortedSetOf<String>()
    decl.modifiers.filterTo(flags) { it in FLAG_MODIFIERS }
    if (decl.sym in composable) flags += "composable"
    if (decl.file?.let { units.files[it]?.generated } == true) flags += "generated"
    if (decl.kind == "getter") flags += "get"
    if (decl.kind == "setter") flags += "set"
    if (decl.kind == "enumEntry") flags += "enumEntry"
    val draft =
      MemberDraft(
        id = decl.sym,
        node = node,
        kind = kind,
        name = nameOf(decl),
        signature = signatureOf(decl),
        file = decl.file,
        span = decl.span?.let { DECL_SPAN.matchEntire(it) }?.groupValues?.drop(1)?.map(String::toInt)?.toIntArray(),
        visibility = VISIBILITIES.firstOrNull { it in decl.modifiers },
        flags = flags.toList(),
        nestedClass = nestedClassOf(decl),
        parent = parent,
      )
    drafts[decl.sym] = draft
    return draft
  }

  private fun addLocalCell(holder: DeclFact): MemberDraft? {
    val parent = holder.owner?.let(::ofDecl)
    return add(holder, "cell", parent)
  }

  private fun addAnonymousCell(cell: CellFact): MemberDraft? {
    val node = units.of(cell.id) ?: return null
    val position = POSITION.matchEntire(cell.id)?.groupValues?.drop(1)?.map(String::toInt)?.toIntArray()
    val parent = ofLocation(cell.id)
    val draft = MemberDraft(cell.id, node, "cell", cell.mechanism, cell.mechanism, Site.of(cell.id)?.path, position, null, emptyList(), parent?.let { drafts[it]?.nestedClass }, parent)
    drafts[cell.id] = draft
    return draft
  }

  /** The initializer of a class: its implicit constructor, else a member named by the class itself. */
  private fun initializerOf(cls: DeclFact): String {
    implicitConstructors[cls.sym]?.let { if (it in drafts) return it }
    if (cls.sym !in drafts) {
      check(!frozen) { "member of ${cls.sym} asked for after the members were numbered" }
      val node = units.ofDecl(cls.sym) ?: cls.sym
      drafts[cls.sym] =
        MemberDraft(
          cls.sym, node, "initializer", "init", "init", cls.file,
          cls.span?.let { DECL_SPAN.matchEntire(it) }?.groupValues?.drop(1)?.map(String::toInt)?.toIntArray(),
          null, listOfNotNull("generated".takeIf { cls.file?.let { f -> units.files[f]?.generated } == true }),
          cls.sym.takeIf { node != it }, null,
        )
    }
    return cls.sym
  }

  /** The member a declaration belongs to. */
  fun ofDecl(sym: String): String? =
    cache.getOrPut(sym) {
      var current = decls[sym] ?: return@getOrPut ""
      var guard = 0
      while (guard++ < 200) {
        if (current.sym in drafts) return@getOrPut current.sym
        if (isStructural(current)) return@getOrPut initializerOf(current)
        current = current.owner?.let { decls[it] } ?: break
      }
      ""
    }.ifEmpty { null }

  /** The member of a location, resolved the way [Units.of] resolves its node. */
  fun ofLocation(location: String): String? {
    var id = withoutContext(location)
    while (id.endsWith(ELEMENT)) id = id.removeSuffix(ELEMENT)
    drafts[id]?.let { return it.id }
    units.nodesById[id]?.let { return ofDecl(it.enclosingDecl) }
    if (id in decls) return ofDecl(id)
    val part = id.lastIndexOf("#<")
    if (part > 0) return ofLocation(id.substring(0, part))
    return null
  }

  fun draft(id: String): MemberDraft? = drafts[id]

  /** Numbers the members by node, then position; sizes them, and counts their lambdas. */
  fun finish(nodeIndex: Map<String, Int>): List<MemberDraft> {
    for (decl in decls.values) if (decl.kind == "lambda") ofDecl(decl.sym)?.let { drafts.getValue(it).lambdas++ }
    frozen = true
    val all = drafts.values.filter { it.node in nodeIndex }
    for ((_, members) in all.groupBy { it.node }) size(members)
    return all.sortedWith(compareBy({ nodeIndex.getValue(it.node) }, { it.span?.get(0) ?: 0 }, { it.span?.get(1) ?: 0 }, { it.id }))
  }

  /**
   * Gives each line of the node to the innermost member whose span holds it, so member sizes never
   * overlap and sum to at most the node's size. A line two members share goes to the smaller span.
   */
  private fun size(members: List<MemberDraft>) {
    val owner = HashMap<Int, MemberDraft>()
    val bySpan = members.filter { it.span != null }.sortedWith(compareByDescending<MemberDraft> { extent(it.span!!) }.thenByDescending { it.id })
    for (m in bySpan) for (line in m.span!![0]..m.span[2]) owner[line] = m
    for (m in owner.values) m.size++
  }

  private fun extent(span: IntArray): Long = (span[2] - span[0]).toLong() * 100_000 + (if (span[2] == span[0]) span[3] - span[1] else span[3])

  private fun nameOf(decl: DeclFact): String =
    when (decl.kind) {
      "ctor" -> decl.owner?.let { decls[it]?.name } ?: decl.name
      "getter", "setter" -> decl.owner?.let { decls[it]?.name } ?: decl.name
      else -> decl.name
    }

  private fun signatureOf(decl: DeclFact): String {
    fun short(type: String?) = type?.replace(TYPE_PACKAGE, "").orEmpty()
    val text =
      when (decl.kind) {
        "fun", "ctor" -> {
          val params = parameters[decl.sym].orEmpty().joinToString(", ") { short(it.type) }
          val returns = if (decl.kind == "fun" && decl.type != null && decl.type != "kotlin.Unit") ": ${short(decl.type)}" else ""
          "${nameOf(decl)}($params)$returns"
        }
        "getter" -> "get ${nameOf(decl)}"
        "setter" -> "set ${nameOf(decl)}"
        "enumEntry" -> decl.name
        else -> decl.type?.let { "${decl.name}: ${short(it)}" } ?: decl.name
      }
    return if (text.length > SIGNATURE_LENGTH) text.take(SIGNATURE_LENGTH - 3) + "..." else text
  }
}
