package com.ryanmoelter.altitude.rules

import java.nio.file.Path
import kotlin.io.path.exists
import kotlin.io.path.readLines
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** An oracle file under `golden/<target>/expected/` and the derived relation it checks. */
private val ORACLES =
  listOf(
    "bindings.jsonl" to "binding",
    "injection-sites.jsonl" to "injectionSite",
    "routes.jsonl" to "route",
    "resolvers.jsonl" to "resolver",
    "screens.jsonl" to "screen",
    "boundaries.jsonl" to "boundary",
  )

/** Free text a rule cannot be expected to word the same way. */
private val IGNORED = setOf("note")

class CheckResult(val text: String, val differences: Int)

/**
 * Compares each oracle file with the derived relation of the same rows. A derived row is cut down
 * to the fields the oracle file uses, so a relation may carry more than the oracle records.
 */
fun check(facts: Path, expected: Path): CheckResult {
  val out = StringBuilder()
  var differences = 0
  for ((oracleName, relation) in ORACLES) {
    val oracleFile = expected.resolve(oracleName)
    if (!oracleFile.exists()) continue
    val oracle = rows(oracleFile)
    val fields = oracle.flatMap { it.keys }.toSortedSet() - IGNORED
    val derivedFile = facts.resolve("$relation.jsonl")
    val derived = if (derivedFile.exists()) rows(derivedFile) else emptyList()
    val want = oracle.map { canonical(it, fields) }.toSortedSet()
    val have = derived.map { canonical(it, fields) }.toSortedSet()
    val missing = want - have
    val extra = have - want
    differences += missing.size + extra.size
    out.appendLine("$oracleName: ${want.size - missing.size} matched, ${missing.size} missing, ${extra.size} extra")
    for (row in missing) out.appendLine("  missing $row")
    for (row in extra) out.appendLine("  extra   $row")
  }
  return CheckResult(out.toString(), differences)
}

private fun rows(file: Path): List<JsonObject> =
  file.readLines().filter { it.isNotBlank() }.map { Json.parseToJsonElement(it).jsonObject }

private fun canonical(row: JsonObject, fields: Set<String>): String =
  JsonObject(fields.filter { it in row }.associateWith { row.getValue(it) }).toString()
