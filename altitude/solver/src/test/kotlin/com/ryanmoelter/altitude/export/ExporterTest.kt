package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.rules.BoundaryFact
import com.ryanmoelter.altitude.rules.EntrypointFact
import com.ryanmoelter.altitude.rules.Rules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject

/**
 * A screen calls a helper and a repository, and the repository calls a database. The screen is an
 * entry host (presentation), the repository calls the boundary (data), and the helper inherits the
 * screen's layer.
 */
class ExporterTest {
  private val screenFile = "app/src/main/kotlin/app/ui/Screen.kt"
  private val repoFile = "app/src/main/kotlin/app/data/Repo.kt"

  private fun cls(sym: String, file: String) = DeclFact(sym, "class", sym.substringAfterLast('/'), "file:$file", file, "1:1-9:1")

  private fun fn(sym: String, owner: String, file: String, line: Int) =
    DeclFact(sym, "fun", sym.substringAfter('.').substringBefore('('), owner, file, "$line:1-$line:9")

  private val screen = cls("class:app/ui/Screen", screenFile)
  private val helper = cls("class:app/ui/Formatter", screenFile)
  private val repo = cls("class:app/data/Repo", repoFile)
  private val show = fn("fun:app/ui/Screen.show()", screen.sym, screenFile, 2)
  private val format = fn("fun:app/ui/Formatter.format()", helper.sym, screenFile, 5)
  private val load = fn("fun:app/data/Repo.load()", repo.sym, repoFile, 2)

  private fun export(): AltitudeExport {
    val facts =
      Facts(
        files = listOf(FileFact(screenFile, ":app", generated = false, sourceSet = "main"), FileFact(repoFile, ":app", generated = false, sourceSet = "main")),
        decls = listOf(screen, helper, repo, show, format, load),
      )
    val derived =
      Derived(
        callEdges =
          listOf(
            CallEdgeFact("$screenFile:3:1-3:9:call", show.sym, format.sym, "static"),
            CallEdgeFact("$screenFile:4:1-4:9:call", show.sym, load.sym, "static"),
          ),
      )
    val rules =
      Rules(
        entrypoints = listOf(EntrypointFact("lifecycleHook", show.sym, file = screenFile, line = 2)),
        boundaries = listOf(BoundaryFact("sqldelight", "sqlRead", "Query.executeAsList", "fun:db/Query.executeAsList()", load.sym, "$repoFile:3:1-3:9:call", access = "read", file = repoFile, line = 3)),
      )
    return Exporter("sample", facts, derived, rules, MetaFact()).build()
  }

  @Test
  fun placesNodesByFlow() {
    val nodes = export().nodes.associateBy { it.id }
    assertEquals(2 to "entryHost", nodes.getValue(screen.sym).let { it.layer to it.layerWhy })
    assertEquals(1 to "boundaryCaller", nodes.getValue(repo.sym).let { it.layer to it.layerWhy })
    assertEquals(2 to "inheritsFromCallers", nodes.getValue(helper.sym).let { it.layer to it.layerWhy })
  }

  @Test
  fun aggregatesCallEdgesWithSites() {
    val edge = export().edges.single { it.from == screen.sym && it.to == repo.sym }
    assertEquals("call", edge.kind)
    assertEquals(1, edge.count)
    assertEquals(true, edge.crossesLayer)
    val files = export().files
    assertEquals(screenFile, files[edge.sites.single().substringBefore(':').toInt()])
  }

  @Test
  fun encodesTheSchemaDeterministically() {
    val first = exportJson.encodeToJsonElement(export()).jsonObject
    assertEquals(first.toString(), exportJson.encodeToJsonElement(export()).toString())
    assertEquals(
      setOf("schema", "schemaVersion", "meta", "files", "containers", "features", "nodes", "edges", "cells", "entrypoints", "boundaries", "bindings", "navigations", "bundles", "patterns", "traces"),
      first.keys,
    )
    assertEquals(export(), exportJson.decodeFromString(AltitudeExport.serializer(), first.toString()))
    assertFalse(first.toString().contains("/Users/"))
  }
}
