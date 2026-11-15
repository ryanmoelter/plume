package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.FactStore
import com.ryanmoelter.altitude.rules.Rules
import java.nio.file.Path
import kotlin.io.path.createDirectories
import kotlin.io.path.deleteIfExists
import kotlin.io.path.writeText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject

val exportJson = Json {
  encodeDefaults = false
  explicitNulls = false
}

/** Builds a JSON object with sorted keys from plain values: strings, numbers, booleans, lists and maps. */
fun jsonObject(values: Map<String, Any?>): JsonObject = JsonObject(values.toSortedMap().mapValues { toJson(it.value) })

private fun toJson(value: Any?): JsonElement =
  when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { it.key.toString() to toJson(it.value) }.toSortedMap())
    is Iterable<*> -> JsonArray(value.map(::toJson))
    else -> JsonPrimitive(value.toString())
  }

/** Node fields a page needs to draw a first view; the rest goes to the detail file when split. */
private val SUMMARY_NODE_FIELDS = setOf("id", "kind", "name", "container", "feature", "file", "line", "generated", "staged", "nonProduction", "size", "layer", "layerWhy", "infrastructure", "roles")

class ExportResult(val files: Map<String, Long>)

/** Above this size the export moves node detail and argument groups into a second file. */
const val SPLIT_BYTES = 4_000_000

/**
 * Writes `altitude.json` for one facts directory. When it would exceed [SPLIT_BYTES], or with
 * [split], node detail (placement, reach, fan-in, the misplaced flag) and the argument groups go to
 * `altitude-nodes.json`. Members and member edges always go to [MEMBERS_FILE], and branch trees to
 * [BRANCHES_FILE], which keeps hop records only for clean segments when it would exceed [SPLIT_BYTES].
 */
fun export(factsDir: Path, out: Path, target: String, golden: Path?, split: Boolean = false): ExportResult {
  val facts = FactStore.read(factsDir)
  val derived = FactStore.readDerived(factsDir)
  val rules = Rules.read(factsDir)
  val meta = FactStore.readMeta(factsDir)
  val queries = golden?.let(::readGolden).orEmpty()
  val detailName = "altitude-nodes.json"
  val exporter = Exporter(target, facts, derived, rules, meta)
  val (all, members) = exporter.buildAll(queries)
  val built = all.copy(meta = all.meta.copy(branchesFile = BRANCHES_FILE))
  out.createDirectories()
  val sizes = LinkedHashMap<String, Long>()
  sizes[MEMBERS_FILE] = write(out.resolve(MEMBERS_FILE), exportJson.encodeToJsonElement(members))
  val trees = exporter.branchTrees(queries)
  val branches = exportJson.encodeToJsonElement(exporter.branchesExport(trees)).let { whole ->
    if (whole.toString().length < SPLIT_BYTES) whole else exportJson.encodeToJsonElement(exporter.branchesExport(trees, withHops = false))
  }
  sizes[BRANCHES_FILE] = write(out.resolve(BRANCHES_FILE), branches)
  val whole = exportJson.encodeToJsonElement(built).jsonObject
  if (!split && whole.toString().length < SPLIT_BYTES) {
    sizes["altitude.json"] = write(out.resolve("altitude.json"), whole)
    out.resolve(detailName).deleteIfExists()
    return ExportResult(sizes)
  }
  val tree = exportJson.encodeToJsonElement(built.copy(meta = built.meta.copy(detailFile = detailName))).jsonObject
  val nodes = tree.getValue("nodes") as JsonArray
  val summary = JsonArray(nodes.map { n -> JsonObject(n.jsonObject.filterKeys { it in SUMMARY_NODE_FIELDS }) })
  val detailNodes = JsonObject(nodes.associate { n -> (n.jsonObject.getValue("id") as JsonPrimitive).content to JsonObject(n.jsonObject.filterKeys { it !in SUMMARY_NODE_FIELDS }) }.toSortedMap())
  val bundles = tree.getValue("bundles").jsonObject
  val detail = JsonObject(mapOf("schemaVersion" to JsonPrimitive(EXPORT_SCHEMA_VERSION), "nodes" to detailNodes, "argGroups" to bundles.getValue("argGroups")))
  sizes["altitude.json"] = write(out.resolve("altitude.json"), JsonObject(tree + ("nodes" to summary) + ("bundles" to JsonObject(bundles - "argGroups"))))
  sizes[detailName] = write(out.resolve(detailName), detail)
  return ExportResult(sizes)
}

private fun write(path: Path, element: JsonElement): Long {
  val text = element.toString() + "\n"
  path.writeText(text)
  return text.toByteArray().size.toLong()
}
