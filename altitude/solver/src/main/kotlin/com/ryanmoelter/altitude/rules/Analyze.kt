package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.model.Models
import com.ryanmoelter.altitude.solver.solve

class Analysis(val derived: Derived, val rules: Rules)

/**
 * Derives the DI bindings first, because their links are edges the solver propagates along, then
 * solves, then reads entry points and boundaries off the solved call graph.
 */
fun analyze(facts: Facts, models: Models = Models.bundled()): Analysis {
  val index = FactIndex(facts)
  val di = deriveDi(index)
  val solved = solve(facts.copy(flows = facts.flows + di.flows), models)
  val derived = applyDi(index, di, solved)
  val routes = deriveRoutes(index, derived)
  val resolvers = deriveResolvers(index, derived)
  val screens = deriveScreens(index)
  return Analysis(
    derived,
    Rules(
      bindings = di.bindings,
      injectionSites = di.sites,
      diUnresolved = di.unresolved,
      routes = routes,
      resolvers = resolvers,
      screens = screens,
      entrypoints = deriveEntrypoints(index, routes, resolvers, screens),
      boundaries = deriveBoundaries(index, derived),
      navigations = deriveNavigations(index, derived, screens),
    ),
  )
}
