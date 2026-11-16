package com.ryanmoelter.altitude.export

import java.security.MessageDigest
import java.util.TreeMap
import kotlinx.serialization.Serializable
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

/** What a hint matches. Every field given must match; globs take `*` and `?`. */
class HintMatch(
  /** A dotted annotation class on the declaration itself, or on a property's getter. */
  val annotation: String? = null,
  val name: String? = null,
  val pkg: String? = null,
  /** A dotted glob over every supertype the sources declare, transitively. */
  val supertype: String? = null,
  /** A role name, or `role:kind` for a role whose evidence lists that kind. */
  val role: String? = null,
) {
  private val nameRegex = name?.let(::glob)
  private val pkgRegex = pkg?.let(::glob)
  private val supertypeRegex = supertype?.let(::glob)

  /** [supertypes] and [roles] are empty for a member, so a hint that names either never matches one. */
  fun matches(subject: HintSubject): Boolean =
    (annotation == null || annotation in subject.annotations) &&
      (nameRegex == null || nameRegex.matches(subject.name)) &&
      (pkgRegex == null || pkgRegex.matches(subject.pkg)) &&
      (supertypeRegex == null || subject.supertypes.any(supertypeRegex::matches)) &&
      (role == null || role in subject.roles)

  fun describe(): Map<String, String> =
    listOfNotNull(annotation?.let { "annotation" to it }, name?.let { "name" to it }, pkg?.let { "package" to it }, supertype?.let { "supertype" to it }, role?.let { "role" to it }).toMap()

  private companion object {
    fun glob(pattern: String): Regex =
      Regex(pattern.split('*').joinToString(".*") { part -> part.split('?').joinToString(".") { Regex.escape(it) } })
  }
}

class HintSubject(
  val name: String,
  val pkg: String,
  val annotations: Set<String>,
  val supertypes: Set<String> = emptySet(),
  val roles: Set<String> = emptySet(),
)

/** [onClasses] and [onMembers] say what the hint votes for; by default a hint that names only an annotation votes for both. */
class LayerHint(
  val id: String,
  val match: HintMatch,
  val layer: Int,
  val weight: Int,
  val pin: Boolean = false,
  val onClasses: Boolean = true,
  val onMembers: Boolean = false,
)

class NeighbourRules(
  val minSiblings: Int = 3,
  val minShare: Double = 0.667,
  /** 1 the file, 2 the package, 3 the parent package. */
  val maxLevel: Int = 3,
  /** The share a container needs when it holds its whole module and source set. */
  val moduleShare: Double = 0.9,
)

/** The format is in `altitude/docs/export.md`. */
class LayerHints(val hints: List<LayerHint>, val neighbours: NeighbourRules = NeighbourRules(), val hash: String = "") {
  /** The rules as `meta` records them. */
  fun describe(file: String): Map<String, Any?> =
    mapOf(
      "file" to file,
      "hash" to hash,
      "rules" to hints.map { h ->
        mapOf("id" to h.id, "match" to h.match.describe(), "layer" to LAYERS[h.layer], "weight" to h.weight, "pin" to h.pin.takeIf { it }, "on" to on(h)).filterValues { it != null }
      },
      "neighbours" to mapOf("minSiblings" to neighbours.minSiblings, "minShare" to neighbours.minShare, "maxLevel" to neighbours.maxLevel, "moduleShare" to neighbours.moduleShare),
    )

  private fun on(h: LayerHint) = listOfNotNull("class".takeIf { h.onClasses }, "member".takeIf { h.onMembers })

  companion object {
    const val FILE = "layer-hints.yaml"
    val NONE = LayerHints(emptyList())

    fun bundled(): LayerHints {
      val text = LayerHints::class.java.classLoader.getResourceAsStream("altitude-models/$FILE")?.bufferedReader()?.readText() ?: return NONE
      return parse(text)
    }

    fun parse(text: String): LayerHints {
      val root = Yaml(SafeConstructor(LoaderOptions())).load<Any?>(text) as? Map<*, *> ?: return NONE
      val layers = (root["layers"] as? List<*>)?.map { it as String } ?: LAYERS
      require(layers == LAYERS) { "$FILE: layers must be $LAYERS" }
      val hints =
        (root["hints"] as? List<*>).orEmpty().map { raw ->
          val map = raw as Map<*, *>
          val id = map["id"] as? String ?: error("$FILE: a hint has no id")
          (map.keys - setOf("id", "match", "layer", "weight", "pin", "on")).firstOrNull()?.let { error("$FILE#$id: unknown key `$it`") }
          val m = map["match"] as? Map<*, *> ?: error("$FILE#$id: no match")
          (m.keys - setOf("annotation", "name", "package", "supertype", "role")).firstOrNull()?.let { error("$FILE#$id: unknown match key `$it`") }
          val match = HintMatch(m["annotation"] as String?, m["name"] as String?, m["package"] as String?, m["supertype"] as String?, m["role"] as String?)
          val layer = LAYERS.indexOf(map["layer"] as? String).also { require(it >= 0) { "$FILE#$id: unknown layer `${map["layer"]}`" } }
          val on = when (val o = map["on"]) {
            null -> if (m.keys == setOf("annotation")) setOf("class", "member") else setOf("class")
            is String -> setOf(o)
            is List<*> -> o.map { it as String }.toSet()
            else -> error("$FILE#$id: `on` is class, member or a list of them")
          }
          require(on.isNotEmpty() && on.all { it == "class" || it == "member" }) { "$FILE#$id: `on` is class, member or a list of them" }
          LayerHint(id, match, layer, (map["weight"] as? Int) ?: 1, map["pin"] == true, "class" in on, "member" in on)
        }
      require(hints.map { it.id }.toSet().size == hints.size) { "$FILE: hint ids repeat" }
      val n = root["neighbours"] as? Map<*, *>
      val neighbours =
        if (n == null) NeighbourRules()
        else NeighbourRules(
          (n["minSiblings"] as? Int) ?: 3,
          (n["minShare"] as? Number)?.toDouble() ?: 0.667,
          (n["maxLevel"] as? Int) ?: 3,
          (n["moduleShare"] as? Number)?.toDouble() ?: 0.9,
        )
      val hash = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).take(8).joinToString("") { "%02x".format(it) }
      return LayerHints(hints, neighbours, hash)
    }
  }
}

/** Where the neighbours vote found its evidence. */
@Serializable
data class NeighboursOut(val level: String, val container: String, val share: Double, val count: Int)

/** One class's or member's layer and the votes behind it. */
class LayerVote(
  val layer: Int?,
  val why: String,
  val scores: Map<Int, Int> = emptyMap(),
  val hints: List<String> = emptyList(),
  val flow: Int? = null,
  val conflict: Boolean = false,
  val neighbours: NeighboursOut? = null,
)

/** A node as the neighbours vote sees it. */
class NeighbourNode(val id: String, val file: String, val module: String, val sourceSet: String, val pkg: String, val loc: Int)

/**
 * Places classes and members by hint weights plus the flow result as one vote of weight 1. A pin
 * wins outright. A tie or no vote leaves a class unplaced, and then [neighbours] may place it.
 */
class LayerPlacer(private val hints: LayerHints) {
  fun placeClass(subject: HintSubject, flow: Int?, flowWhy: String): LayerVote {
    val matched = hints.hints.filter { it.onClasses && it.match.matches(subject) }
    return vote(matched, flow, flowWhy, flowWeight = 1, inherited = false)
  }

  /** A member keeps [classLayer] unless the hints that match the member itself outvote it. */
  fun placeMember(subject: HintSubject, classLayer: Int?): LayerVote {
    val matched = hints.hints.filter { it.onMembers && it.match.matches(subject) }
    if (matched.isEmpty()) return LayerVote(classLayer, "class")
    val v = vote(matched, classLayer, "class", flowWeight = 1, inherited = true)
    return if (v.layer == null || v.layer == classLayer) LayerVote(classLayer, "class") else v
  }

  private fun vote(matched: List<LayerHint>, base: Int?, baseWhy: String, flowWeight: Int, inherited: Boolean): LayerVote {
    val scores = TreeMap<Int, Int>()
    base?.let { scores.merge(it, flowWeight, Int::plus) }
    for (h in matched) scores.merge(h.layer, h.weight, Int::plus)
    val ids = matched.map { it.id }
    val flow = if (inherited) null else base
    val disagrees = base != null && matched.any { it.layer != base }
    val pins = matched.filter { it.pin }
    if (pins.isNotEmpty()) {
      val top = pins.maxOf { it.weight }
      val layers = pins.filter { it.weight == top }.map { it.layer }.distinct()
      if (layers.size > 1) return LayerVote(null, "pinTie", scores, ids, flow, conflict = true)
      val pin = pins.first { it.weight == top }
      return LayerVote(pin.layer, "pin:${pin.id}", scores, ids, flow, conflict = disagrees)
    }
    if (matched.isEmpty()) return LayerVote(base, baseWhy, scores, ids, flow)
    val best = scores.values.max()
    val winners = scores.filterValues { it == best }.keys
    val second = scores.values.sortedDescending().getOrElse(1) { 0 }
    val conflict = disagrees || second > 0 && best - second <= 1
    if (winners.size > 1) return LayerVote(null, "tie", scores, ids, flow, conflict = true)
    val layer = winners.single()
    val forWinner = matched.filter { it.layer == layer }.map { it.id }
    val why = if (forWinner.isEmpty()) baseWhy else "hints:" + forWinner.joinToString("+") + (if (base == layer) "+$baseWhy" else "")
    return LayerVote(layer, why, scores, ids, flow, conflict)
  }

  /**
   * Places each unplaced node by the line-weighted layers of the placed nodes around it: its file,
   * then its package, then the parent package, within its module and source set. Only [placed]
   * counts as evidence, so nothing this places moves another.
   */
  fun neighbours(nodes: List<NeighbourNode>, placed: Map<String, Int>): Map<String, LayerVote> {
    val rules = hints.neighbours
    val byUnit = nodes.groupBy { it.module to it.sourceSet }
    val out = TreeMap<String, LayerVote>()
    for (node in nodes.sortedBy { it.id }) {
      if (node.id in placed) continue
      val unit = byUnit.getValue(node.module to node.sourceSet)
      val levels = levels(node, unit).take(rules.maxLevel)
      for ((i, level) in levels.withIndex()) {
        val (name, container, members) = level
        val siblings = members.filter { it.id != node.id }
        val evidence = siblings.filter { it.id in placed }
        val onlyOther = name == "file" && siblings.size == 1 && evidence.size == 1
        if (evidence.isEmpty() || evidence.size < rules.minSiblings && !onlyOther) continue
        val (layer, share) = plurality(evidence, placed) ?: continue
        val needed = if (members.size == unit.size) maxOf(rules.moduleShare, rules.minShare) else rules.minShare
        if (share < needed) continue
        // A whole module is no evidence below moduleShare, so it is no disagreement either.
        val outer = levels.getOrNull(i + 1)?.third?.takeIf { it.size < unit.size }?.filter { it.id != node.id && it.id in placed }?.takeIf { it.size > evidence.size }
        val conflict = outer != null && plurality(outer, placed)?.first != layer
        out[node.id] = LayerVote(layer, "neighbours", conflict = conflict, neighbours = NeighboursOut(name, container, round3(share), evidence.size))
        break
      }
    }
    return out
  }

  private fun levels(node: NeighbourNode, unit: List<NeighbourNode>): List<Triple<String, String, List<NeighbourNode>>> {
    val out = ArrayList<Triple<String, String, List<NeighbourNode>>>()
    out += Triple("file", node.file, unit.filter { it.file == node.file })
    out += Triple("package", node.pkg, unit.filter { it.pkg == node.pkg })
    val parent = node.pkg.substringBeforeLast('.', "")
    out += Triple("parent", parent, unit.filter { parent.isEmpty() || it.pkg == parent || it.pkg.startsWith("$parent.") })
    return out
  }

  /** The layer with the most lines among [evidence], and its share; null on a tie. */
  private fun plurality(evidence: List<NeighbourNode>, placed: Map<String, Int>): Pair<Int, Double>? {
    val lines = TreeMap<Int, Int>()
    for (n in evidence) lines.merge(placed.getValue(n.id), maxOf(n.loc, 1), Int::plus)
    val best = lines.values.max()
    val winners = lines.filterValues { it == best }.keys
    if (winners.size > 1) return null
    return winners.single() to best.toDouble() / lines.values.sum()
  }
}
