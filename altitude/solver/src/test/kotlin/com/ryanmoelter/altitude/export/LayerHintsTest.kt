package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.facts.SupertypeFact
import com.ryanmoelter.altitude.rules.Rules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.encodeToJsonElement

/**
 * The bundled sample rules on a fixture nothing else places: a step whose supertype chain reaches
 * ComposeStep is presentation and its composable member is ui, and a `*Repository` is data. Then
 * the vote itself and the neighbours fallback, on hand-made subjects.
 */
class LayerHintsTest {
  private val stepFile = "app/src/main/kotlin/app/ui/HomeStep.kt"
  private val repoFile = "app/src/main/kotlin/app/data/GroupsRepository.kt"
  private val baseFile = "app/src/main/kotlin/app/ui/BaseStep.kt"

  private fun decl(sym: String, kind: String, owner: String, file: String, line: Int, span: Int = 1) =
    DeclFact(sym, kind, sym.substringAfterLast('/').substringAfterLast('.').substringBefore('('), owner, file, "$line:1-${line + span - 1}:9")

  private val base = decl("class:app/ui/BaseStep", "class", "file:$baseFile", baseFile, 1, 9)
  private val baseRun = decl("fun:app/ui/BaseStep.run()", "fun", base.sym, baseFile, 2)
  private val step = decl("class:app/ui/HomeStep", "class", "file:$stepFile", stepFile, 1, 20)
  private val content = decl("fun:app/ui/HomeStep.Content()", "fun", step.sym, stepFile, 2, 5)
  private val onTap = decl("fun:app/ui/HomeStep.onTap()", "fun", step.sym, stepFile, 8)
  private val onBack = decl("fun:app/ui/HomeStep.onBack()", "fun", step.sym, stepFile, 10)
  private val repo = decl("class:app/data/GroupsRepository", "class", "file:$repoFile", repoFile, 1, 9)
  private val load = decl("fun:app/data/GroupsRepository.load()", "fun", repo.sym, repoFile, 2)

  private fun exporter(): Exporter {
    val facts =
      Facts(
        files = listOf(stepFile, repoFile, baseFile).map { FileFact(it, ":app", generated = false, sourceSet = "main") },
        decls = listOf(base, baseRun, step, content, onTap, onBack, repo, load),
        annotations = listOf(AnnotationFact(content.sym, COMPOSABLE)),
        supertypes = listOf(SupertypeFact(step.sym, base.sym), SupertypeFact(base.sym, "class:com/ryanmoelter/magellanx/compose/ComposeStep")),
      )
    return Exporter("sample", facts, Derived(), Rules(), MetaFact())
  }

  @Test
  fun appliesTheSampleRules() {
    val (export, members) = exporter().buildAll()
    val nodes = export.nodes.associateBy { it.id }
    val home = nodes.getValue(step.sym)
    assertEquals(2 to "hints:compose-step-is-presentation", home.layer to home.layerWhy)
    assertEquals(listOf("compose-step-is-presentation"), home.layerHints)
    assertNull(home.layerFlowVote)
    assertEquals(1 to "hints:repository-is-data", nodes.getValue(repo.sym).let { it.layer to it.layerWhy })
    val byId = members.members.associateBy { it.id }
    val c = byId.getValue(content.sym)
    assertEquals(3 to "hints:composable-is-ui", c.ly to c.lyWhy)
    assertEquals(mapOf(2 to 1, 3 to 3), c.layerScores)
    assertEquals(2 to "class", byId.getValue(onTap.sym).let { it.ly to it.lyWhy })
    assertNull(byId.getValue(onTap.sym).layerScores)
    assertEquals(mapOf(2 to 2, 3 to 5), home.layerSizes)
  }

  @Test
  fun buildsTheSameExportTwice() {
    fun encoded() = exporter().buildAll().let { (e, m) -> exportJson.encodeToJsonElement(e).toString() + exportJson.encodeToJsonElement(m).toString() }
    assertEquals(encoded(), encoded())
  }

  private fun hint(id: String, layer: String, weight: Int, pin: Boolean = false, onMembers: Boolean = false, name: String? = null, role: String? = null, annotation: String? = null) =
    LayerHint(id, HintMatch(annotation = annotation, name = name, role = role), LAYERS.indexOf(layer), weight, pin, onClasses = true, onMembers = onMembers)

  private fun subject(name: String, roles: Set<String> = emptySet(), annotations: Set<String> = emptySet()) = HintSubject(name, "app", annotations, emptySet(), roles)

  @Test
  fun aHintIsOutvotedByTheFlowAndAnotherHint() {
    val placer = LayerPlacer(LayerHints(listOf(hint("repo", "data", 2, name = "*Repository"), hint("host", "presentation", 2, role = "entryPoint"))))
    val vote = placer.placeClass(subject("SettingsRepository", roles = setOf("entryPoint")), flow = 2, flowWhy = "entryHost")
    assertEquals(2, vote.layer)
    assertEquals(mapOf(1 to 2, 2 to 3), vote.scores)
    assertEquals("hints:host+entryHost", vote.why)
    assertTrue(vote.conflict)
  }

  @Test
  fun aTieOrAPinDecides() {
    val tie = LayerPlacer(LayerHints(listOf(hint("repo", "data", 1, name = "*Repository"))))
    assertNull(tie.placeClass(subject("ARepository"), flow = 2, flowWhy = "entryHost").layer)
    val pinned = LayerPlacer(LayerHints(listOf(hint("repo", "data", 1, pin = true, name = "*Repository"), hint("host", "presentation", 5, role = "entryPoint"))))
    val vote = pinned.placeClass(subject("ARepository", roles = setOf("entryPoint")), flow = 2, flowWhy = "entryHost")
    assertEquals(1 to "pin:repo", vote.layer to vote.why)
  }

  @Test
  fun aMemberOutvotesItsClassOnlyByItsOwnHints() {
    val placer = LayerPlacer(LayerHints(listOf(hint("ui", "ui", 3, onMembers = true, annotation = "a.Ui"), hint("weak", "data", 1, onMembers = true, name = "load*"))))
    assertEquals(3, placer.placeMember(subject("Content", annotations = setOf("a.Ui")), classLayer = 2).layer)
    // One vote against the class's own one ties, and a tie keeps the class's layer.
    assertEquals(2 to "class", placer.placeMember(subject("loadAll"), classLayer = 2).let { it.layer to it.why })
    assertEquals(2 to "class", placer.placeMember(subject("render"), classLayer = 2).let { it.layer to it.why })
  }

  private fun node(id: String, file: String, pkg: String, loc: Int = 10) = NeighbourNode(id, file, ":app", "main", pkg, loc)

  private val placer = LayerPlacer(LayerHints.NONE)

  @Test
  fun placesAClassByItsPackage() {
    val nodes = listOf(node("a", "A.kt", "p"), node("b", "B.kt", "p"), node("c", "C.kt", "p"), node("u", "U.kt", "p"), node("other", "O.kt", "q"))
    val out = placer.neighbours(nodes, mapOf("a" to 1, "b" to 1, "c" to 1, "other" to 2))
    val u = out.getValue("u")
    assertEquals(1 to "neighbours", u.layer to u.why)
    assertEquals(NeighboursOut("package", "p", 1.0, 3), u.neighbours)
  }

  @Test
  fun leavesASplitPackageUnplaced() {
    val nodes = listOf(node("a", "A.kt", "p.x"), node("b", "B.kt", "p.x"), node("c", "C.kt", "p.x"), node("d", "D.kt", "p.x"), node("u", "U.kt", "p.x"))
    assertEquals(emptyMap(), placer.neighbours(nodes, mapOf("a" to 1, "b" to 1, "c" to 2, "d" to 2)))
  }

  @Test
  fun placesFromHintAndFlowPlacementsOnly() {
    // `v` shares its file only with `u`, which the neighbours place; that never counts for `v`.
    val nodes = listOf(node("a", "A.kt", "p"), node("b", "B.kt", "p"), node("c", "C.kt", "p"), node("u", "U.kt", "p"), node("v", "U.kt", "p"))
    val out = placer.neighbours(nodes, mapOf("a" to 1, "b" to 1, "c" to 1))
    assertEquals("package", out.getValue("v").neighbours?.level)
    assertEquals(3, out.getValue("v").neighbours?.count)
  }
}
