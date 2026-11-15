package com.ryanmoelter.altitude.facts

import java.nio.file.Path
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.readLines
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json

/**
 * Reads and writes one JSON Lines file per relation. Lines are distinct and sorted by their text,
 * so the same rows always produce the same bytes.
 */
object FactStore {
  private val json = Json {
    encodeDefaults = false
    explicitNulls = false
    ignoreUnknownKeys = true
  }
  private val prettyJson = Json(json) {
    prettyPrint = true
    encodeDefaults = true
  }

  fun write(dir: Path, facts: Facts, meta: MetaFact) {
    dir.createDirectories()
    val rows = LinkedHashMap<String, Int>()
    fun <T> relation(name: String, serializer: KSerializer<T>, values: List<T>) {
      rows[name] = writeRelation(dir, name, serializer, values)
    }
    relation("module", ModuleFact.serializer(), facts.modules)
    relation("file", FileFact.serializer(), facts.files)
    relation("decl", DeclFact.serializer(), facts.decls)
    relation("supertype", SupertypeFact.serializer(), facts.supertypes)
    relation("override", OverrideFact.serializer(), facts.overrides)
    relation("actualFor", ActualForFact.serializer(), facts.actuals)
    relation("annotation", AnnotationFact.serializer(), facts.annotations)
    relation("node", NodeFact.serializer(), facts.nodes)
    relation("call", CallFact.serializer(), facts.calls)
    relation("arg", ArgFact.serializer(), facts.args)
    relation("flow", FlowFact.serializer(), facts.flows)
    relation("libraryLambdaCall", LambdaCallFact.serializer(), facts.libraryLambdaCalls)
    relation("unresolved", UnresolvedFact.serializer(), facts.unresolved)
    relation("sqlStatement", SqlStatementFact.serializer(), facts.sqlStatements)
    relation("pluginOption", PluginOptionFact.serializer(), facts.pluginOptions)
    dir
      .resolve("meta.json")
      .writeText(prettyJson.encodeToString(MetaFact.serializer(), meta.copy(rows = rows)) + "\n")
  }

  fun writeDerived(dir: Path, derived: Derived) {
    dir.createDirectories()
    writeRelation(dir, "flowDerived", FlowFact.serializer(), derived.flows)
    writeRelation(dir, "fnValue", FnValueFact.serializer(), derived.fnValues)
    writeRelation(dir, "callEdge", CallEdgeFact.serializer(), derived.callEdges)
    writeRelation(dir, "fanOut", FanOutFact.serializer(), derived.fanOuts)
    writeRelation(dir, "unmodelledLambdaCall", LambdaCallFact.serializer(), derived.unmodelledLambdaCalls)
    writeRelation(dir, "cell", CellFact.serializer(), derived.cells)
    writeRelation(dir, "cellWrite", CellAccessFact.serializer(), derived.cellWrites)
    writeRelation(dir, "cellRead", CellAccessFact.serializer(), derived.cellReads)
    writeRelation(dir, "flowInContext", FlowFact.serializer(), derived.contextFlows)
  }

  fun read(dir: Path): Facts =
    Facts(
      modules = readRelation(dir, "module", ModuleFact.serializer()),
      files = readRelation(dir, "file", FileFact.serializer()),
      decls = readRelation(dir, "decl", DeclFact.serializer()),
      supertypes = readRelation(dir, "supertype", SupertypeFact.serializer()),
      overrides = readRelation(dir, "override", OverrideFact.serializer()),
      actuals = readRelation(dir, "actualFor", ActualForFact.serializer()),
      annotations = readRelation(dir, "annotation", AnnotationFact.serializer()),
      nodes = readRelation(dir, "node", NodeFact.serializer()),
      calls = readRelation(dir, "call", CallFact.serializer()),
      args = readRelation(dir, "arg", ArgFact.serializer()),
      flows = readRelation(dir, "flow", FlowFact.serializer()),
      libraryLambdaCalls = readRelation(dir, "libraryLambdaCall", LambdaCallFact.serializer()),
      unresolved = readRelation(dir, "unresolved", UnresolvedFact.serializer()),
      sqlStatements = readRelation(dir, "sqlStatement", SqlStatementFact.serializer()),
      pluginOptions = readRelation(dir, "pluginOption", PluginOptionFact.serializer()),
    )

  fun readDerived(dir: Path): Derived =
    Derived(
      flows = readRelation(dir, "flowDerived", FlowFact.serializer()),
      fnValues = readRelation(dir, "fnValue", FnValueFact.serializer()),
      callEdges = readRelation(dir, "callEdge", CallEdgeFact.serializer()),
      fanOuts = readRelation(dir, "fanOut", FanOutFact.serializer()),
      unmodelledLambdaCalls = readRelation(dir, "unmodelledLambdaCall", LambdaCallFact.serializer()),
      cells = readRelation(dir, "cell", CellFact.serializer()),
      cellWrites = readRelation(dir, "cellWrite", CellAccessFact.serializer()),
      cellReads = readRelation(dir, "cellRead", CellAccessFact.serializer()),
      contextFlows = readRelation(dir, "flowInContext", FlowFact.serializer()),
    )

  fun readMeta(dir: Path): MetaFact =
    json.decodeFromString(MetaFact.serializer(), dir.resolve("meta.json").readText())

  fun <T> lines(serializer: KSerializer<T>, values: List<T>): List<String> =
    values.mapTo(sortedSetOf()) { json.encodeToString(serializer, it) }.toList()

  fun <T> writeRelation(
    dir: Path,
    name: String,
    serializer: KSerializer<T>,
    values: List<T>,
  ): Int {
    val lines = lines(serializer, values)
    dir.resolve("$name.jsonl").writeText(lines.joinToString("") { it + "\n" })
    return lines.size
  }

  fun <T> readRelation(dir: Path, name: String, serializer: KSerializer<T>): List<T> {
    val file = dir.resolve("$name.jsonl")
    if (!file.exists()) return emptyList()
    return file.readLines().filter { it.isNotEmpty() }.map { json.decodeFromString(serializer, it) }
  }
}
