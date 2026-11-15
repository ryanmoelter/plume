package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.CallEdgeFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.FlowFact

class DiResult(
  val bindings: List<BindingFact> = emptyList(),
  val sites: List<InjectionSiteFact> = emptyList(),
  val unresolved: List<DiUnresolvedFact> = emptyList(),
  /** `di` edges from what a provider yields to each site it satisfies. */
  val flows: List<FlowFact> = emptyList(),
) {
  operator fun plus(other: DiResult): DiResult =
    DiResult(bindings + other.bindings, sites + other.sites, unresolved + other.unresolved, flows + other.flows)
}

fun deriveDi(index: FactIndex): DiResult = Metro(index).derive()

/**
 * Adds a `di` call edge from each call of a graph accessor to the provider that supplies it, since
 * the generated graph that does the call is not in the sources.
 */
fun applyDi(index: FactIndex, di: DiResult, solved: Derived): Derived {
  val byAccessor = HashMap<String, MutableList<InjectionSiteFact>>()
  for (site in di.sites) {
    val decl = index.decls[site.site] ?: continue
    if (decl.kind != "prop" && decl.kind != "fun") continue
    val target = if (decl.kind == "prop") "${decl.sym}#<get>" else decl.sym
    byAccessor.getOrPut(target) { ArrayList() } += site
  }
  val edges = ArrayList<CallEdgeFact>()
  for (call in index.calls) {
    val sites = byAccessor[call.target] ?: continue
    for (site in sites) {
      for (provider in site.providers) {
        if (provider !in index.decls) continue
        edges +=
          CallEdgeFact(
            call = call.id,
            caller = call.callerDecl,
            callee = provider,
            via = "di",
            binding = provider,
            graph = site.graph,
          )
      }
    }
  }
  if (edges.isEmpty()) return solved
  val all = (solved.callEdges + edges).distinct().sortedWith(compareBy({ it.call }, { it.callee }, { it.via }, { it.graph }))
  return solved.copy(callEdges = all)
}
