package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.solver.solve
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.Tracer

/** The facts of `src/test/resources/fixture/flow`, solved. */
object FlowFixture {
  val input = AnalysisInput(listOf(Fixture.module("flow")))

  fun extract(): Facts = AltitudeSession.open(input).use(::extractFacts)

  val facts: Facts by lazy { extract() }
  val derived: Derived by lazy { solve(facts) }
  val program: Program by lazy { Program(facts, derived) }
  val tracer: Tracer by lazy { Tracer(program) }
}
