package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.CellAccessFact
import com.ryanmoelter.altitude.facts.CellFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.rules.Rules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.encodeToJsonElement

/**
 * A screen class with a cell property, a composable function whose lambda holds a local cell and
 * calls a repository, a helper function, and a nested class that calls the helper. The repository
 * is an object with one function. Member edges keep the calls inside the screen that node edges drop.
 */
class MembersTest {
  private val screenFile = "app/src/main/kotlin/app/ui/Screen.kt"
  private val repoFile = "app/src/main/kotlin/app/data/Repo.kt"

  private fun decl(sym: String, kind: String, name: String, owner: String, file: String, span: String, modifiers: List<String> = emptyList(), type: String? = null) =
    DeclFact(sym, kind, name, owner, file, span, type, modifiers)

  private val screen = decl("class:app/ui/Screen", "class", "Screen", "file:$screenFile", screenFile, "1:1-30:1")
  private val init = decl("ctor:app/ui/Screen()", "ctor", "<init>", screen.sym, screenFile, "1:1-30:1", listOf("implicit"))
  private val state = decl("prop:app/ui/Screen.state", "prop", "state", screen.sym, screenFile, "2:3-2:40", listOf("val"), "kotlinx.coroutines.flow.MutableStateFlow<kotlin.Int>")
  private val show = decl("fun:app/ui/Screen.show()", "fun", "show", screen.sym, screenFile, "4:3-12:3", type = "kotlin.Unit")
  private val lambda = decl("$screenFile:5:10-7:5:lambda", "lambda", "<lambda>", show.sym, screenFile, "5:10-7:5")
  private val local = decl("$screenFile:6:7-6:30:local", "local", "count", lambda.sym, screenFile, "6:7-6:30", type = "androidx.compose.runtime.MutableState<kotlin.Int>")
  private val render = decl("fun:app/ui/Screen.render()", "fun", "render", screen.sym, screenFile, "14:3-16:3", listOf("private"))
  private val inner = decl("class:app/ui/Screen.Inner", "class", "Inner", screen.sym, screenFile, "18:3-28:3")
  private val go = decl("fun:app/ui/Screen.Inner.go()", "fun", "go", inner.sym, screenFile, "19:5-21:5", listOf("suspend"))
  private val repo = decl("class:app/data/Repo", "object", "Repo", "file:$repoFile", repoFile, "1:1-9:1")
  private val load = decl("fun:app/data/Repo.load(kotlin/String)", "fun", "load", repo.sym, repoFile, "2:3-4:3", type = "kotlin.Unit")
  private val q = decl("${load.sym}#q", "param", "q", load.sym, repoFile, "2:12-2:21", type = "kotlin.String")
  private val decls = listOf(screen, init, state, show, lambda, local, render, inner, go, repo, load, q)

  private fun call(line: Int, caller: DeclFact, callee: DeclFact) = "$screenFile:$line:5-$line:13:call".let { id -> CallFact(id, caller.sym, callee.sym, "static", targetInSource = true) to CallEdgeFact(id, caller.sym, callee.sym, "static") }

  private val calls = listOf(call(8, show, render), call(6, lambda, load), call(20, go, render), call(15, render, load))
  private val stateCell = CellFact("$screenFile:2:15-2:40:call", state.sym, "MutableStateFlow")
  private val localCell = CellFact("$screenFile:6:20-6:30:call", local.sym, "ComposeMutableState")
  private val write = CallFact("$screenFile:9:5-9:20:call", show.sym, "fun:kotlinx/coroutines/flow/MutableStateFlow.setValue", "virtual")
  private val read = CallFact("$screenFile:20:20-20:30:call", go.sym, "fun:kotlinx/coroutines/flow/StateFlow.getValue", "virtual")

  private fun exporter(): Exporter {
    val facts =
      Facts(
        files = listOf(FileFact(screenFile, ":app", generated = false, sourceSet = "main"), FileFact(repoFile, ":app", generated = false, sourceSet = "main")),
        decls = decls,
        annotations = listOf(AnnotationFact(show.sym, COMPOSABLE)),
        calls = calls.map { it.first } + write + read,
        flows = listOf(FlowFact(state.sym, q.sym, "arg", "$screenFile:15:5-15:12")),
      )
    val derived =
      Derived(
        callEdges = calls.map { it.second },
        cells = listOf(stateCell, localCell),
        cellWrites = listOf(CellAccessFact(stateCell.id, write.id, "value="), CellAccessFact(localCell.id, write.id, "value=")),
        cellReads = listOf(CellAccessFact(stateCell.id, read.id, "value")),
      )
    return Exporter("sample", facts, derived, Rules(), MetaFact())
  }

  private val queries =
    listOf(
      GoldenQuery("calls#1", "--from Screen.show --to Repo.load", null, null),
      GoldenQuery("values#1", "--value --from ${state.sym} --to ${q.sym}", null, null),
    )

  private fun build() = exporter().let { it to it.buildAll(queries) }

  @Test
  fun coversEveryDeclarationOfANodeOnce() {
    val (exporter, built) = build()
    val (export, members) = built
    val nodeIndex = export.nodes.withIndex().associate { it.value.id to it.index }
    val byId = members.members.associateBy { it.id }
    assertEquals(members.members.size, byId.size)
    for (d in decls) {
      if (exporter.members.isStructural(d)) continue
      val member = byId.getValue(assertNotNull(exporter.members.ofDecl(d.sym), d.sym))
      assertEquals(nodeIndex.getValue(exporter.units.ofDecl(d.sym)!!), member.n, d.sym)
    }
    assertEquals(
      mapOf(init.sym to "initializer", state.sym to "cell", show.sym to "function", local.sym to "cell", render.sym to "function", go.sym to "function", load.sym to "function"),
      members.members.associate { it.id to it.k },
    )
    assertEquals(show.sym, exporter.members.ofDecl(lambda.sym))
    assertEquals(1, byId.getValue(show.sym).lam)
    assertEquals(listOf("composable"), byId.getValue(show.sym).fl)
    assertEquals("private", byId.getValue(render.sym).v)
    assertEquals(inner.sym, members.classes[byId.getValue(go.sym).c!!].id)
    assertEquals(show.sym, members.members[byId.getValue(local.sym).p!!].id)
    assertEquals(listOf(1), byId.getValue(local.sym).cell)
  }

  @Test
  fun sizesMembersWithinTheirNode() {
    val (export, members) = build().second
    for ((i, node) in export.nodes.withIndex()) {
      assertTrue(members.members.filter { it.n == i }.sumOf { it.s } <= node.size.loc, node.id)
    }
    val byId = members.members.associateBy { it.id }
    assertEquals(8, byId.getValue(show.sym).s)
    assertEquals(1, byId.getValue(local.sym).s)
  }

  @Test
  fun aggregatesMemberEdgesToNodeEdges() {
    val (export, members) = build().second
    val m = members.members
    val n = export.nodes
    for ((i, edge) in export.edges.withIndex()) {
      val witnesses = members.edges.filter { it.e == i }
      assertTrue(witnesses.isNotEmpty(), "${edge.from} -> ${edge.to} ${edge.kind}")
      for (w in witnesses) assertEquals(Triple(edge.from, edge.to, edge.kind), Triple(n[m[w.a].n].id, n[m[w.b].n].id, w.k))
      assertTrue(witnesses.sumOf { it.c } >= edge.count)
    }
    for (e in members.edges) assertEquals(m[e.a].n == m[e.b].n, e.e == null)
    val inNode = members.edges.filter { it.e == null }.map { Triple(m[it.a].id, m[it.b].id, it.k) }.toSet()
    assertTrue(Triple(show.sym, render.sym, "call") in inNode)
    assertTrue(Triple(go.sym, render.sym, "call") in inNode)
    assertTrue(Triple(show.sym, state.sym, "cellWrite") in inNode)
    assertTrue(Triple(show.sym, local.sym, "cellWrite") in inNode)
    assertTrue(Triple(state.sym, go.sym, "cellRead") in inNode)
    assertTrue(members.edges.any { m[it.a].id == show.sym && m[it.b].id == load.sym && it.k == "call" && it.e != null })
  }

  @Test
  fun placesEveryTraceHopInItsNode() {
    val (export, members) = build().second
    val nodeIndex = export.nodes.withIndex().associate { it.value.id to it.index }
    val byId = members.members.associateBy { it.id }
    val hops = export.traces.flatMap { t -> t.legs.flatMap { it.hops } }
    assertEquals(setOf("call", "value"), export.traces.filter { t -> t.legs.any { it.hops.isNotEmpty() } }.map { it.kind }.toSet())
    for (hop in hops) {
      hop.fromMember?.let { assertEquals(nodeIndex.getValue(hop.fromNode!!), byId.getValue(it).n) }
      hop.toMember?.let { assertEquals(nodeIndex.getValue(hop.toNode!!), byId.getValue(it).n) }
      hop.memberEdge?.let { e -> assertEquals(Pair(hop.fromMember, hop.toMember), members.edges[e].let { byIdx -> members.members[byIdx.a].id to members.members[byIdx.b].id }) }
    }
    val call = export.traces.first { it.kind == "call" }.legs.single()
    assertEquals(listOf(show.sym, render.sym), call.hops.map { it.fromMember })
    assertEquals(1, call.paths)
    assertEquals(1L, call.equalCostPaths)
    val value = export.traces.first { it.kind == "value" }.legs.single()
    assertEquals(listOf(state.sym to load.sym), value.hops.map { it.fromMember to it.toMember })
    assertEquals(1, value.cost?.length)
    assertEquals(2, value.skeleton.size)
  }

  @Test
  fun writesTheMembersFileDeterministically() {
    val first = exportJson.encodeToJsonElement(build().second.second).toString()
    assertEquals(first, exportJson.encodeToJsonElement(build().second.second).toString())
    assertFalse(first.contains("/Users/"))
    assertEquals(build().second.second, exportJson.decodeFromString(MembersExport.serializer(), first))
  }
}
