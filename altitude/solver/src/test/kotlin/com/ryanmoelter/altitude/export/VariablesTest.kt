package com.ryanmoelter.altitude.export

import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.rules.Rules
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.encodeToJsonElement

private const val F = "app/src/main/kotlin/app/ui/Screen.kt"

/**
 * `show(p)` copies `p` into a local `x`, and a lambda passed to `map` captures `x` and passes it
 * to `other(q)`. The variables are `p`, `x`, the lambda's `it`, `q` and the receivers; the capture
 * is a reference to `x`, not a variable of its own. Edges run `p → x` inside `show` and `x → q`
 * across members, the second refining the member edge from `show` to `other`.
 */
class VariablesTest {
  private val screen = DeclFact("class:app/ui/Screen", "class", "Screen", "file:$F", F, "1:1-30:1")
  private val show = DeclFact("fun:app/ui/Screen.show(kotlin/Int)", "fun", "show", screen.sym, F, "2:1-20:1")
  private val other = DeclFact("fun:app/ui/Screen.other(kotlin/Int)", "fun", "other", screen.sym, F, "22:1-25:1")
  private val p = DeclFact("${show.sym}#p", "param", "p", show.sym, F, "2:10-2:11", "kotlin.Int", index = 0)
  private val q = DeclFact("${other.sym}#q", "param", "q", other.sym, F, "22:11-22:12", "kotlin.Int", index = 0)
  private val x = DeclFact("$F:3:5-3:20:local", "local", "x", show.sym, F, "3:5-3:20", "kotlin.Int", listOf("val"))
  private val lambda = DeclFact("$F:4:10-6:1:lambda", "lambda", "<lambda>", show.sym, F, "4:10-6:1", "(Item) -> Unit", fnTyped = true)
  private val it = DeclFact("${lambda.sym}#it", "param", "it", lambda.sym, F, "4:10-4:10", "Item", index = 0)

  private val pRef = NodeFact("$F:3:9-3:10:paramRef", "paramRef", show.sym, "kotlin.Int", target = p.sym)
  private val lambdaExpr = NodeFact("$F:4:10-6:1:lambdaExpr", "lambdaExpr", show.sym, target = lambda.sym)
  private val xRef = NodeFact("$F:5:9-5:10:localRef", "localRef", lambda.sym, "kotlin.Int", target = x.sym)
  private val map = CallFact("$F:4:1-6:1:call", show.sym, "fun:kotlin/collections/map@kotlin/collections/Iterable<T>(kotlin/Function1<T,R>)", "static")
  private val callOther = CallFact("$F:5:3-5:11:call", lambda.sym, other.sym, "static", targetInSource = true)

  private fun exporter(): Exporter {
    val facts =
      Facts(
        files = listOf(FileFact(F, ":app", generated = false, sourceSet = "main")),
        decls = listOf(screen, show, other, p, q, x, lambda, it),
        nodes = listOf(pRef, lambdaExpr, xRef),
        calls = listOf(map, callOther),
        args = listOf(ArgFact(map.id, "${map.target}#transform", 0, lambdaExpr.id, "positional"), ArgFact(callOther.id, q.sym, 0, xRef.id, "positional")),
        flows =
          listOf(
            FlowFact(p.sym, pRef.id, "read", pRef.id),
            FlowFact(pRef.id, x.sym, "init", x.sym),
            FlowFact(x.sym, xRef.id, "capture", xRef.id),
            FlowFact(xRef.id, q.sym, "arg", callOther.id),
          ),
      )
    return Exporter("sample", facts, Derived(), Rules(), MetaFact())
  }

  private fun build(): Triple<VariableTable, MembersExport, List<String>> {
    val exporter = exporter()
    val (_, members) = exporter.buildAll()
    val locations = listOf(p.sym, pRef.id, x.sym, xRef.id, q.sym, "${show.sym}#<ret>")
    return Triple(exporter.variables(locations), members, locations)
  }

  @Test
  fun findsTheVariablesOfEachMember() {
    val (vars, members) = build()
    val byName = vars.vars.associateBy { it.n }
    assertEquals("param", byName.getValue("p").k)
    assertEquals("local", byName.getValue("x").k)
    assertEquals("lambdaParam", byName.getValue("it").k)
    assertEquals("map → it", byName.getValue("it").lbl)
    assertEquals(listOf(0), byName.getValue("x").cap)
    assertEquals("show", members.members[byName.getValue("x").m].name)
    assertEquals("temp", byName.getValue("return").k)
    assertEquals(vars.of(x.sym), vars.of(xRef.id))
  }

  @Test
  fun everyHopLocationsVariableBelongsToItsMemberOrThatMembersParent() {
    val (vars, members, locations) = build()
    val exporter = exporter().also { it.buildAll() }
    val index = members.members.withIndex().associate { it.value.id to it.index }
    for (l in locations) {
      val v = assertNotNull(vars.of(l), l)
      val member = index.getValue(exporter.members.ofLocation(l)!!)
      val owner = vars.vars[v].m
      assertTrue(owner == member || members.members[owner].p == member, l)
    }
  }

  @Test
  fun edgesRunBetweenVariablesAndNameTheMemberEdgeTheyRefine() {
    val (vars, members) = build()
    val names = vars.vars.map { it.n }
    val edges = vars.edges.associate { "${names[it.a]}→${names[it.b]}" to it }
    assertEquals(setOf("p→x", "x→q"), edges.keys)
    assertEquals(null, edges.getValue("p→x").e)
    val memberEdge = members.edges[edges.getValue("x→q").e!!]
    assertEquals(listOf("show", "other"), listOf(members.members[memberEdge.a].name, members.members[memberEdge.b].name))
  }

  @Test
  fun theFileIsTheSameOnEveryRunAndHoldsNoAbsolutePath() {
    fun text(): String {
      val exporter = exporter()
      exporter.buildAll()
      return exportJson.encodeToJsonElement(exporter.variablesExport(exporter.variables(listOf(xRef.id)))).toString()
    }
    val first = text()
    assertEquals(first, text())
    assertFalse("/Users/" in first)
    assertFalse("\"/" in first)
  }
}
