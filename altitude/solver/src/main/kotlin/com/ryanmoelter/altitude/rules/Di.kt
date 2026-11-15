package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.FlowFact

class DiResult(
  val bindings: List<BindingFact> = emptyList(),
  val sites: List<InjectionSiteFact> = emptyList(),
  val unresolved: List<DiUnresolvedFact> = emptyList(),
  /** `di` edges from what a provider yields to each site it satisfies. */
  val flows: List<FlowFact> = emptyList(),
)

fun deriveDi(index: FactIndex): DiResult = DiResult()

fun applyDi(index: FactIndex, di: DiResult, solved: Derived): Derived = solved
