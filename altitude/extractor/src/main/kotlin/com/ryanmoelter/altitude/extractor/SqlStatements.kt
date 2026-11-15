package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.PluginOptionFact
import com.ryanmoelter.altitude.facts.SqlStatementFact
import com.ryanmoelter.altitude.manifest.Manifest
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.extension
import kotlin.io.path.invariantSeparatorsPathString
import kotlin.io.path.isDirectory
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.nameWithoutExtension
import kotlin.io.path.readLines

private val LABEL = Regex("""^([A-Za-z_][A-Za-z0-9_]*)\s*(:|\{)\s*$""")
private val WRITES = setOf("INSERT", "UPDATE", "DELETE", "REPLACE", "UPSERT")
private val KEYWORD = Regex("""\b[A-Za-z]+\b""")

/**
 * The labelled statements of every `.sq` file under a mirrored project's `src/<source set>/sqldelight`.
 * SQLDelight names the queries class after the file and puts it in the package the directory spells.
 */
fun Manifest.sqlStatements(): List<SqlStatementFact> {
  val root = Path.of(repoRoot)
  val out = ArrayList<SqlStatementFact>()
  for (projectDir in compilations.map { it.projectDir }.distinct().sorted()) {
    val src = root.resolve(projectDir).resolve("src")
    if (!src.isDirectory()) continue
    for (sourceSet in src.listDirectoryEntries().sorted()) {
      val base = sourceSet.resolve("sqldelight")
      if (!base.isDirectory()) continue
      val files = Files.walk(base).use { paths -> paths.filter { it.extension == "sq" }.sorted().toList() }
      for (file in files) {
        val packagePath = base.relativize(file.parent).invariantSeparatorsPathString
        val owner = (if (packagePath.isEmpty()) "" else "$packagePath/") + file.nameWithoutExtension
        out += sqlStatements(file.readLines(), "class:${owner}Queries", root.relativize(file).invariantSeparatorsPathString)
      }
    }
  }
  return out
}

fun sqlStatements(lines: List<String>, cls: String, file: String): List<SqlStatementFact> {
  val out = ArrayList<SqlStatementFact>()
  var index = 0
  while (index < lines.size) {
    val match = LABEL.matchEntire(lines[index])
    if (match == null) {
      index++
      continue
    }
    val start = index
    val grouped = match.groupValues[2] == "{"
    index++
    val body = StringBuilder()
    while (index < lines.size && LABEL.matchEntire(lines[index]) == null) {
      val line = lines[index].substringBefore("--")
      if (grouped && line.trim() == "}") break
      body.append(line).append('\n')
      index++
      if (!grouped && line.trimEnd().endsWith(";")) break
    }
    val statements = if (grouped) body.split(';') else listOf(body.toString())
    val access = if (statements.any(::writes)) "write" else "read"
    out += SqlStatementFact(cls, match.groupValues[1], file, start + 1, access)
  }
  return out
}

/** `WITH … SELECT` reads, and `WITH … INSERT` writes. */
private fun writes(statement: String): Boolean {
  val words = KEYWORD.findAll(statement).map { it.value.uppercase() }.toList()
  val first = words.firstOrNull() ?: return false
  return first in WRITES || first == "WITH" && words.any { it in WRITES }
}

fun Manifest.pluginOptions(): List<PluginOptionFact> =
  compilations.flatMap { compilation ->
    compilation.compilerPlugins.options.map {
      PluginOptionFact(compilation.projectPath, it.pluginId, it.key, it.value)
    }
  }
