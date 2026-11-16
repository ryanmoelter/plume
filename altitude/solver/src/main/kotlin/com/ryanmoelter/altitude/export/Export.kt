package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.FactStore
import com.ryanmoelter.altitude.rules.Rules
import java.nio.file.Path
import java.security.MessageDigest
import kotlin.io.path.createDirectories
import kotlin.io.path.deleteIfExists
import kotlin.io.path.inputStream
import kotlin.io.path.isRegularFile
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.name
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

/** Bump when the exporter's output changes for the same facts and options. */
const val EXPORTER_VERSION = "4.1"

/**
 * One id for the files of one export run: a hash of the facts' bytes, [EXPORTER_VERSION] and the
 * options. A page that loads several files checks they agree.
 */
fun exportId(factsDir: Path, target: String, split: Boolean, queries: List<GoldenQuery>): String {
  val digest = MessageDigest.getInstance("SHA-256")
  val factFiles = factsDir.listDirectoryEntries().filter { it.isRegularFile() && (it.name.endsWith(".jsonl") || it.name == "meta.json") }.sortedBy { it.name }
  for (file in factFiles) {
    digest.update(file.name.toByteArray())
    file.inputStream().use { input ->
      val buffer = ByteArray(1 shl 16)
      while (true) {
        val n = input.read(buffer)
        if (n < 0) break
        digest.update(buffer, 0, n)
      }
    }
  }
  val options = "exporter=$EXPORTER_VERSION target=$target split=$split golden=" + queries.joinToString("|") { "${it.name}:${it.query}" }
  digest.update(options.toByteArray())
  return digest.digest().take(8).joinToString("") { "%02x".format(it) }
}

private fun stamped(element: JsonElement, id: String): JsonObject {
  val file = element.jsonObject
  val meta = (file["meta"] as? JsonObject).orEmpty() + ("exportId" to JsonPrimitive(id))
  return JsonObject(file + ("meta" to JsonObject(meta)))
}

/** Node fields a page needs to draw a first view; the rest goes to the detail file when split. */
private val SUMMARY_NODE_FIELDS = setOf("id", "kind", "name", "container", "feature", "file", "line", "generated", "staged", "nonProduction", "size", "layer", "layerWhy", "layerSizes", "layers", "infrastructure", "roles")

class ExportResult(val files: Map<String, Long>)

/** Above this size the export moves node detail and argument groups into a second file. */
const val SPLIT_BYTES = 4_000_000

/** Above this size the branches file keeps hop records only for clean segments. */
const val BRANCHES_MAX_BYTES = 8_000_000

/**
 * Writes `altitude.json` for one facts directory. When it would exceed [SPLIT_BYTES], or with
 * [split], node detail (placement, reach, fan-in, the misplaced flag) and the argument groups go to
 * `altitude-nodes.json`. Members go to [MEMBERS_FILE], variables to [VARIABLES_FILE], and branch
 * trees to [BRANCHES_FILE] with their sink terminals in [BRANCH_SINKS_FILE]. The branches file keeps
 * hop records only for clean segments when it would exceed [BRANCHES_MAX_BYTES].
 */
fun export(factsDir: Path, out: Path, target: String, golden: Path?, split: Boolean = false): ExportResult {
  val facts = FactStore.read(factsDir)
  val derived = FactStore.readDerived(factsDir)
  val rules = Rules.read(factsDir)
  val meta = FactStore.readMeta(factsDir)
  val queries = golden?.let(::readGolden).orEmpty()
  val detailName = "altitude-nodes.json"
  val id = exportId(factsDir, target, split, queries)
  val exporter = Exporter(target, facts, derived, rules, meta)
  val (all, members) = exporter.buildAll(queries)
  out.createDirectories()
  val sizes = LinkedHashMap<String, Long>()
  sizes[MEMBERS_FILE] = write(out.resolve(MEMBERS_FILE), exportJson.encodeToJsonElement(members), id)
  val trees = exporter.branchTrees(queries)
  var branchFiles = exporter.branchFiles(trees)
  val traceLocations = all.traces.flatMap { t -> t.legs.flatMap { leg -> leg.hops.flatMap { listOf(it.from, it.to) } } }
  var vars = exporter.variables(traceLocations + branchFiles.hopLocations())
  var branches = exportJson.encodeToJsonElement(branchFiles.export(target, vars))
  if (branches.toString().length >= BRANCHES_MAX_BYTES) {
    branchFiles = exporter.branchFiles(trees, withHops = false)
    vars = exporter.variables(traceLocations + branchFiles.hopLocations())
    branches = exportJson.encodeToJsonElement(branchFiles.export(target, vars))
  }
  sizes[BRANCHES_FILE] = write(out.resolve(BRANCHES_FILE), branches, id)
  sizes[BRANCH_SINKS_FILE] = write(out.resolve(BRANCH_SINKS_FILE), exportJson.encodeToJsonElement(branchFiles.sinksExport(target, vars)), id)
  sizes[VARIABLES_FILE] = write(out.resolve(VARIABLES_FILE), exportJson.encodeToJsonElement(exporter.variablesExport(vars)), id)
  val built = exporter.withVariables(all, vars).let { it.copy(meta = it.meta.copy(branchesFile = BRANCHES_FILE, branchSinksFile = BRANCH_SINKS_FILE, variablesFile = VARIABLES_FILE)) }
  val whole = exportJson.encodeToJsonElement(built).jsonObject
  if (!split && whole.toString().length < SPLIT_BYTES) {
    sizes["altitude.json"] = write(out.resolve("altitude.json"), whole, id)
    out.resolve(detailName).deleteIfExists()
    return ExportResult(sizes)
  }
  val tree = exportJson.encodeToJsonElement(built.copy(meta = built.meta.copy(detailFile = detailName))).jsonObject
  val nodes = tree.getValue("nodes") as JsonArray
  val summary = JsonArray(nodes.map { n -> JsonObject(n.jsonObject.filterKeys { it in SUMMARY_NODE_FIELDS }) })
  val detailNodes = JsonObject(nodes.associate { n -> (n.jsonObject.getValue("id") as JsonPrimitive).content to JsonObject(n.jsonObject.filterKeys { it !in SUMMARY_NODE_FIELDS }) }.toSortedMap())
  val bundles = tree.getValue("bundles").jsonObject
  val detail = JsonObject(mapOf("schemaVersion" to JsonPrimitive(EXPORT_SCHEMA_VERSION), "nodes" to detailNodes, "argGroups" to bundles.getValue("argGroups")))
  sizes["altitude.json"] = write(out.resolve("altitude.json"), JsonObject(tree + ("nodes" to summary) + ("bundles" to JsonObject(bundles - "argGroups"))), id)
  sizes[detailName] = write(out.resolve(detailName), detail, id)
  return ExportResult(sizes)
}

private fun write(path: Path, element: JsonElement, id: String): Long {
  val text = stamped(element, id).toString() + "\n"
  path.writeText(text)
  return text.toByteArray().size.toLong()
}
