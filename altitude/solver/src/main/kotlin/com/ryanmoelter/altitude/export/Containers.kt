package com.ryanmoelter.altitude.export

/** One level of the containment tree. A node's own class is the leaf below its file. */
data class Container(
  val id: String,
  val kind: String,
  val parent: String?,
  val name: String,
  val qualified: String,
  val depth: Int,
)

/**
 * The tree module > sourceSet > package segment > file, and the default feature of each node: the
 * package one segment below its module's root package, the longest package prefix every hand-written
 * file of the module shares. A file in the root package itself has the root as its feature.
 */
class Containment(units: Units) {
  val containers: List<Container>
  val parentOf: Map<String, String>
  /** Each node's containers, outermost first. */
  val chain: Map<String, List<String>>
  /** A node's feature key: `feature:<module>/<package>`. */
  val featureOf: Map<String, String>
  val features: List<Feature>

  data class Feature(val id: String, val module: String, val pkg: String, val packageContainers: List<String>)

  init {
    val all = sortedMapOf<String, Container>()
    fun add(c: Container) {
      all.putIfAbsent(c.id, c)
    }
    val chains = sortedMapOf<String, List<String>>()
    for (node in units.nodes.values) {
      val module = "module:${node.module}"
      add(Container(module, "module", null, node.module, node.module, 0))
      val sourceSet = "sourceSet:${node.module}/${node.sourceSet}"
      add(Container(sourceSet, "sourceSet", module, node.sourceSet, "${node.module}/${node.sourceSet}", 1))
      val ids = mutableListOf(module, sourceSet)
      var parent = sourceSet
      val segments = if (node.pkg.isEmpty()) emptyList() else node.pkg.split('.')
      for (i in segments.indices) {
        val qualified = segments.take(i + 1).joinToString(".")
        val id = "package:${node.module}/${node.sourceSet}/$qualified"
        add(Container(id, "package", parent, segments[i], qualified, 2 + i))
        ids += id
        parent = id
      }
      val file = "file:${node.file}"
      add(Container(file, "file", parent, node.file.substringAfterLast('/'), node.file, 2 + segments.size))
      ids += file
      chains[node.id] = ids
    }
    containers = all.values.toList()
    parentOf = containers.filter { it.parent != null }.associate { it.id to it.parent!! }
    chain = chains

    val roots =
      units.nodes.values.groupBy { it.module }.mapValues { (_, nodes) ->
        val handWritten = nodes.filter { !it.generated }.ifEmpty { nodes }
        handWritten.map { it.pkg.split('.').filter(String::isNotEmpty) }.reduce { a, b -> a.zip(b).takeWhile { it.first == it.second }.map { it.first } }
      }
    val featureOf = sortedMapOf<String, String>()
    val featurePackages = sortedMapOf<String, MutableSet<String>>()
    for (node in units.nodes.values) {
      val root = roots.getValue(node.module)
      val segments = node.pkg.split('.').filter(String::isNotEmpty)
      val featurePkg =
        if (segments.size > root.size && segments.take(root.size) == root) segments.take(root.size + 1)
        else if (segments.take(root.size) == root) root
        else segments.take(1)
      val pkg = featurePkg.joinToString(".")
      val id = "feature:${node.module}/$pkg"
      featureOf[node.id] = id
      val container = chains.getValue(node.id).firstOrNull { all.getValue(it).kind == "package" && all.getValue(it).qualified == pkg }
      featurePackages.getOrPut(id) { sortedSetOf() }.apply { container?.let { add(it) } }
    }
    this.featureOf = featureOf
    features =
      featurePackages.map { (id, containers) ->
        val module = id.removePrefix("feature:").substringBeforeLast('/')
        Feature(id, module, id.substringAfterLast('/'), containers.toList())
      }
  }
}
