package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived

private const val TO_SCHEMA = "fun:com/expediagroup/graphql/generator/toSchema("
private const val TOP_LEVEL_OBJECT = "ctor:com/expediagroup/graphql/generator/TopLevelObject("
private const val GRAPHQL_IGNORE = "com/expediagroup/graphql/generator/annotations/GraphQLIgnore"
private const val REGISTER = "fun:org/dataloader/DataLoaderRegistry.register("
private const val KOTLIN_DATA_LOADER = "class:com/expediagroup/graphql/dataloader/KotlinDataLoader"
private val ROOT_KINDS = listOf("queries" to "query", "mutations" to "mutation", "subscriptions" to "subscription")
private val TYPE_NAME = Regex("""[A-Za-z_][\w.]*""")
private val ANY_FUNCTIONS = setOf("equals", "hashCode", "toString")

/** E7–E10: the operations, field resolvers and DataLoaders of every `toSchema` call. */
fun deriveResolvers(index: FactIndex, derived: Derived): List<ResolverFact> {
  val rows = ArrayList<ResolverFact>()
  val roots = LinkedHashSet<String>()
  val packages = LinkedHashSet<String>()
  val operations = ArrayList<DeclFact>()

  for (schema in index.calls.filter { it.target.startsWith(TO_SCHEMA) }) {
    index.argNodes(schema, "config").mapNotNull(index.callsByResult::get).forEach { config ->
      index.argNodes(config, "supportedPackages").flatMap { index.elements(it) }.mapNotNullTo(packages) { index.literalString(it.node) }
    }
    for ((param, kind) in ROOT_KINDS) {
      for (root in index.argNodes(schema, param).flatMap { index.elements(it) }.mapNotNull { rootClass(index, it.node) }) {
        roots += root
        for (function in resolverFunctions(index, root)) {
          operations += function
          rows += resolver(index, kind, kind.replaceFirstChar(Char::uppercase), function) ?: continue
        }
      }
    }
  }

  for (cls in outputTypes(index, operations, packages) - roots) {
    val type = CallableId.parse(cls.replaceFirst("class:", "ctor:"))?.name ?: continue
    resolverFunctions(index, cls).mapNotNullTo(rows) { resolver(index, "field", type, it) }
  }
  rows += dataLoaders(index)
  return rows.distinct().sortedWith(compareBy({ it.kind }, { it.type }, { it.field }, { it.decl }))
}

private fun rootClass(index: FactIndex, node: String): String? {
  val wrapper = index.callsByResult[node]?.takeIf { it.target.startsWith(TOP_LEVEL_OBJECT) }
  val value = wrapper?.let { index.argNodes(it, 0).firstOrNull() } ?: node
  return dottedClassOf(index.nodes[value]?.type)?.let(index.classByDottedName::get)
}

private fun resolverFunctions(index: FactIndex, cls: String): List<DeclFact> =
  index.memberFunctions(cls).filter { function ->
    index.isPublic(function) && function.name !in ANY_FUNCTIONS && !index.hasAnnotation(function.sym, GRAPHQL_IGNORE)
  }

private fun resolver(index: FactIndex, kind: String, type: String, function: DeclFact): ResolverFact? {
  return ResolverFact(
    kind = kind,
    type = type,
    field = function.name,
    decl = function.sym,
    file = function.file ?: return null,
    line = index.line(function) ?: return null,
  )
}

/** E9: the classes the operations can return, closed over members and subtypes. */
private fun outputTypes(index: FactIndex, operations: List<DeclFact>, packages: Set<String>): Set<String> {
  fun supported(cls: String): Boolean {
    val pkg = cls.substringAfter(':').substringBeforeLast('/', "").replace('/', '.')
    return packages.any { pkg.startsWith(it) }
  }
  fun classesIn(decl: DeclFact): List<String> =
    TYPE_NAME.findAll(decl.typeExpanded ?: decl.type ?: "").mapNotNull { index.classByDottedName[it.value] }.filter(::supported).toList()

  val kept = LinkedHashSet<String>()
  val queue = ArrayDeque(operations.flatMap(::classesIn))
  while (queue.isNotEmpty()) {
    val cls = queue.removeFirst()
    // graphql-kotlin represents a value class as the type it wraps, so it has no fields.
    if (index.decls[cls]?.let { index.has(it, "value") } == true || !kept.add(cls)) continue
    queue += index.subtypeClosure(cls).filter(::supported)
    for (member in index.members[cls].orEmpty()) {
      if (member.kind !in setOf("fun", "prop") || !index.isPublic(member)) continue
      if (index.hasAnnotation(member.sym, GRAPHQL_IGNORE)) continue
      queue += classesIn(member)
    }
  }
  return kept
}

/** E10. */
private fun dataLoaders(index: FactIndex): List<ResolverFact> {
  val rows = ArrayList<ResolverFact>()
  for (register in index.calls.filter { it.target.startsWith(REGISTER) }) {
    val name = index.argNodes(register, 0).firstNotNullOfOrNull(index::constString) ?: continue
    val loader = index.argNodes(register, 1).firstNotNullOfOrNull(index.callsByResult::get) ?: continue
    val decl = index.decls[loader.target] ?: continue
    rows += loaderRow(index, name, decl, registeredAt(index, register)) ?: continue
  }
  for (cls in index.subtypeClosure(KOTLIN_DATA_LOADER).mapNotNull(index.decls::get)) {
    val property = index.members[cls.sym].orEmpty().firstOrNull { it.kind == "prop" && it.name == "dataLoaderName" } ?: continue
    val sources = listOf(property.sym, "${property.sym}#<get>#<ret>").flatMap { index.flowsInto[it].orEmpty() }
    val name = sources.firstNotNullOfOrNull { index.constString(it.from) } ?: continue
    rows += loaderRow(index, name, cls, null) ?: continue
  }
  return rows
}

private fun registeredAt(index: FactIndex, call: CallFact): String? {
  val file = index.fileOf(call.id) ?: return null
  return "$file:${index.lineOf(call.id) ?: return null}"
}

private fun loaderRow(index: FactIndex, name: String, decl: DeclFact, registeredAt: String?): ResolverFact? {
  return ResolverFact(
    kind = "dataLoader",
    type = "DataLoader",
    field = name,
    decl = decl.sym,
    registeredAt = registeredAt,
    file = decl.file ?: return null,
    line = index.line(decl) ?: return null,
  )
}
