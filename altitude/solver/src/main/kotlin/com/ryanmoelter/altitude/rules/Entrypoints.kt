package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.Derived

fun deriveRoutes(index: FactIndex, derived: Derived): List<RouteFact> = emptyList()

fun deriveResolvers(index: FactIndex, derived: Derived): List<ResolverFact> = emptyList()

fun deriveScreens(index: FactIndex): List<ScreenFact> = emptyList()

fun deriveNavigations(index: FactIndex, derived: Derived, screens: List<ScreenFact>): List<NavigationFact> =
  emptyList()

fun deriveEntrypoints(
  index: FactIndex,
  routes: List<RouteFact>,
  resolvers: List<ResolverFact>,
  screens: List<ScreenFact>,
): List<EntrypointFact> = emptyList()
