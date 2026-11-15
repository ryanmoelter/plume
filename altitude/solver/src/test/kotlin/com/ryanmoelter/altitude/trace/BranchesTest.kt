package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.NodeFact
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

private const val FILE = "src/App.kt"

/**
 * Two fixtures. In the first, `main` passes a root value to `f` from two calls, and each call's
 * result reaches its own terminal, so `f`'s parameter sits on both paths under different calls: a
 * merge. In the second, a root value is built into an object with a sibling, and three properties
 * are read back: `a` as built, `b` (a field mismatch) and `c`, which reaches no terminal.
 */
class BranchesTest {
  private val main = DeclFact("fun:app/main()", "fun", "main", "file:$FILE", FILE, "1:1-20:1")
  private val f = DeclFact("fun:app/f()", "fun", "f", "file:$FILE", FILE, "30:1-40:1")
  private val param = DeclFact("fun:app/f()#p", "param", "p", f.sym, FILE, "30:7-30:8", index = 0)
  private val ret = "${f.sym}#<ret>"

  private fun at(line: Int, kind: String) = "$FILE:$line:1-$line:9:$kind"

  private fun node(line: Int, kind: String, scope: DeclFact = main, target: String? = null) = NodeFact(at(line, kind), kind, scope.sym, target = target)

  private fun flow(from: String, to: String, kind: String = "assign", at: String = from) = FlowFact(from, to, kind, at)

  private val root = node(1, "localRef")
  private val arg1 = node(10, "localRef")
  private val arg2 = node(11, "localRef")
  private val call1 = CallFact(at(10, "call"), main.sym, f.sym, "static", targetInSource = true, result = at(10, "callResult"))
  private val call2 = CallFact(at(11, "call"), main.sym, f.sym, "static", targetInSource = true, result = at(11, "callResult"))
  private val inF = node(31, "paramRef", f, target = param.sym)
  private val end1 = node(12, "localRef")
  private val end2 = node(13, "localRef")

  private val callsProgram =
    Program(
      Facts(
        files = listOf(FileFact(FILE, ":", generated = false)),
        decls = listOf(main, f, param),
        nodes = listOf(root, arg1, arg2, inF, end1, end2, NodeFact(call1.result!!, "callResult", main.sym, target = call1.id), NodeFact(call2.result!!, "callResult", main.sym, target = call2.id)),
        calls = listOf(call1, call2),
        args = listOf(ArgFact(call1.id, param.sym, 0, arg1.id, "positional"), ArgFact(call2.id, param.sym, 0, arg2.id, "positional")),
        flows =
          listOf(
            flow(root.id, arg1.id),
            flow(root.id, arg2.id),
            flow(arg1.id, param.sym, "arg", call1.id),
            flow(arg2.id, param.sym, "arg", call2.id),
            flow(param.sym, inF.id, "read"),
            flow(inF.id, ret, "return"),
            flow(ret, call1.result, "return", call1.id),
            flow(ret, call2.result, "return", call2.id),
            flow(call1.result, end1.id),
            flow(call2.result, end2.id),
          ),
      ),
      Derived(),
    )

  private val callsTerminals = Terminals { mapOf(end1.id to TerminalKey("sink", 1), end2.id to TerminalKey("sink", 2))[it] }

  private val propA = DeclFact("prop:app/Box.a", "prop", "a", "class:app/Box", FILE, "50:1-50:9")
  private val propB = DeclFact("prop:app/Box.b", "prop", "b", "class:app/Box", FILE, "51:1-51:9")
  private val propC = DeclFact("prop:app/Box.c", "prop", "c", "class:app/Box", FILE, "52:1-52:9")
  private val built = node(2, "localRef")
  private val sibling = node(3, "localRef")
  private val box = CallFact(at(4, "call"), main.sym, "ctor:app/Box()", "static", targetInSource = true, result = at(4, "callResult"))
  private val readA = node(5, "propRef", target = propA.sym)
  private val readB = node(6, "propRef", target = propB.sym)
  private val readC = node(7, "propRef", target = propC.sym)
  private val gotA = node(8, "localRef")
  private val gotB = node(9, "localRef")

  private val boxProgram =
    Program(
      Facts(
        files = listOf(FileFact(FILE, ":", generated = false)),
        decls = listOf(main, propA, propB, propC),
        nodes = listOf(built, sibling, readA, readB, readC, gotA, gotB, NodeFact(box.result!!, "callResult", main.sym, target = box.id)),
        calls = listOf(box),
        args = listOf(ArgFact(box.id, "ctor:app/Box()#a", 0, built.id, "positional"), ArgFact(box.id, "ctor:app/Box()#b", 1, sibling.id, "positional")),
        flows =
          listOf(
            flow(built.id, box.result, "partOf", box.id),
            flow(sibling.id, box.result, "partOf", box.id),
            flow(box.result, readA.id, "memberOf", readA.id),
            flow(box.result, readB.id, "memberOf", readB.id),
            flow(box.result, readC.id, "memberOf", readC.id),
            flow(readA.id, gotA.id),
            flow(readB.id, gotB.id),
          ),
      ),
      Derived(),
    )

  private val boxTerminals = Terminals { mapOf(gotA.id to TerminalKey("ui", 1), gotB.id to TerminalKey("ui", 2), sibling.id to TerminalKey("entry", 3))[it] }

  private fun tree(program: Program, direction: Direction, root: Set<String>, terminals: Terminals): BranchTree {
    val result = BranchSearch(program).search(direction, root, terminals, BranchOptions(emptySet()))
    return BranchTree(direction, root, emptySet(), result.truncated, result.paths, program)
  }

  private fun BranchTree.pointAt(location: String): BranchTree.Point =
    points.single { it.node != 0 && nodes[it.node].state!!.location == location }

  @Test
  fun pathsThroughOneLocationUnderTwoCallsMerge() {
    val tree = tree(callsProgram, Direction.FORWARD, setOf(root.id), callsTerminals)
    assertEquals(listOf(end1.id, end2.id), tree.terminals.map { tree.nodes[it.node].state!!.location })
    val merges = tree.points.filter { it.kind == "merge" }.map { tree.nodes[it.node].state!!.location }
    assertEquals(listOf(param.sym, param.sym), merges)
  }

  @Test
  fun eachTerminalsSegmentsChainToTheTracePath() {
    for ((program, terminals, root) in listOf(Triple(callsProgram, callsTerminals, root.id), Triple(boxProgram, boxTerminals, built.id))) {
      val tree = tree(program, Direction.FORWARD, setOf(root), terminals)
      assertTrue(tree.terminals.isNotEmpty())
      for (terminal in tree.terminals) {
        val goal = tree.nodes[terminal.node].state!!.location
        val run = ValueSearch(program, TraceOptions().searchBudget).run(setOf(root), ValueGoal.Locations(setOf(goal)))
        assertEquals(run.hopsTo(run.end!!), tree.hopNodes(terminal).map { tree.nodes[it].step })
      }
    }
  }

  @Test
  fun aJoinNamesTheOtherValuesBuiltInAndASplitTheOtherPropertiesRead() {
    val tree = tree(boxProgram, Direction.FORWARD, setOf(built.id), boxTerminals)
    val atBox = tree.points.indexOf(tree.pointAt(box.result!!))
    val siblings = tree.siblings.filter { it.point == atBox }.associate { s -> s.kind to s.values.map { it.location to it.name } }
    assertEquals(mapOf("join" to listOf(sibling.id to "b"), "split" to listOf(readC.id to "c")), siblings)
  }

  @Test
  fun aReadOfAnotherFieldThanTheOneBuiltInIsAFieldMismatch() {
    val tree = tree(boxProgram, Direction.FORWARD, setOf(built.id), boxTerminals)
    val mismatched = tree.nodes.drop(1).filter { it.fieldMismatch != null }.map { it.state!!.location to it.fieldMismatch }
    assertEquals(listOf(readB.id to "a"), mismatched)
    val toB = tree.terminals.single { it.path.key.ref == 2 }.path.hops
    assertEquals(listOf(null, "a", null), boxProgram.fieldMismatches(toB))
  }

  @Test
  fun aBackwardTreeEndsAtTheRoot() {
    val tree = tree(boxProgram, Direction.BACKWARD, setOf(gotA.id), boxTerminals)
    assertEquals(listOf(sibling.id), tree.terminals.map { tree.nodes[it.node].state!!.location })
    val hops = tree.hopNodes(tree.terminals.single()).map { tree.nodes[it].step!! }
    assertEquals(listOf(sibling.id, box.result, readA.id), hops.map { it.from })
    assertEquals(gotA.id, hops.last().to)
  }

  @Test
  fun treesAreTheSameOnEveryRun() {
    fun render(t: BranchTree) =
      t.points.map { "${it.kind} ${t.nodes[it.node].state?.location}" } + t.segments.map { "${it.a}-${it.b} ${it.hops}" } + t.terminals.map { "${it.path.key} ${it.segments}" }
    val first = render(tree(callsProgram, Direction.FORWARD, setOf(root.id), callsTerminals))
    repeat(3) { assertEquals(first, render(tree(callsProgram, Direction.FORWARD, setOf(root.id), callsTerminals))) }
  }
}
