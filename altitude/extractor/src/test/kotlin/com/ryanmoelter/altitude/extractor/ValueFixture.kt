package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.solver.solve
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.Tracer

/** The facts of `src/test/resources/fixture/value`, solved. */
object ValueFixture {
  val facts: Facts by lazy {
    AltitudeSession.open(AnalysisInput(listOf(Fixture.module("value")))).use(::extractFacts)
  }
  val derived: Derived by lazy { solve(facts) }
  val program: Program by lazy { Program(facts, derived) }
  val tracer: Tracer by lazy { Tracer(program) }

  private val names: Map<String, String> by lazy { facts.decls.associate { it.sym to it.name } }

  /** `File.kt:LINE:call(name)` for the [nth] call of [name] inside the function [within]. */
  fun call(within: String, name: String, nth: Int = 0): String {
    val scope = facts.decls.single { it.kind == "fun" && it.name == within }
    val id =
      facts.calls
        .filter { it.id.startsWith("${scope.file}:") && names[it.target] == name }
        .filter { call -> generateSequence(call.callerDecl) { owner(it) }.any { it == scope.sym } }
        .map { it.id }
        .sorted()[nth]
    val line = id.removePrefix("${scope.file}:").substringBefore(':')
    return "${scope.file!!.substringAfterLast('/')}:$line:call($name)"
  }

  private fun owner(sym: String): String? = facts.decls.firstOrNull { it.sym == sym }?.owner

  /** The value trace between the calls of [from] and [to] inside the function [within]. */
  fun trace(within: String, from: String = "source", to: String = "sink", nth: Int = 0): String =
    tracer.traceValue(call(within, from), call(within, to, nth))
}
