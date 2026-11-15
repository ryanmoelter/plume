package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.Derived

private const val MAGELLAN = "class:com/ryanmoelter/magellanx"

/** E11, in the order the kinds are checked. */
private val SCREEN_KINDS =
  listOf(
    "journey" to setOf("$MAGELLAN/compose/ComposeJourney"),
    "step" to setOf("$MAGELLAN/compose/ComposeStep", "$MAGELLAN/compose/SimpleComposeStep", "$MAGELLAN/core/Navigable"),
    "section" to setOf("$MAGELLAN/compose/ComposeSection", "$MAGELLAN/core/Displayable"),
  )

internal val LIFECYCLE_HOOKS = setOf("onCreate", "onShow", "onResume", "onPause", "onHide", "onDestroy", "onBackPressed")

private const val NAVIGATOR = "fun:com/ryanmoelter/magellanx/compose/navigation/ComposeNavigator."
private val NAVIGATOR_OPS = setOf("goTo", "goBack", "navigate", "replace", "resetWithRoot")

/** E11–E13. */
fun deriveScreens(index: FactIndex): List<ScreenFact> =
  index.classes
    .filter { it.kind != "interface" }
    .mapNotNull { cls ->
      val closure = index.supertypeClosure(cls.sym).toSet()
      val kind = SCREEN_KINDS.firstOrNull { (_, bases) -> bases.any { it in closure } }?.first ?: return@mapNotNull null
      val overrides = index.memberFunctions(cls.sym).filter { index.has(it, "override") }
      ScreenFact(
        cls = cls.sym,
        kind = kind,
        content = overrides.firstOrNull { it.name == "Content" && index.parameters(it.sym).isEmpty() }?.sym,
        lifecycle = overrides.map { it.name }.filter { it in LIFECYCLE_HOOKS }.distinct().sorted(),
        note = "abstract".takeIf { index.has(cls, "abstract") },
        file = cls.file ?: return@mapNotNull null,
        line = index.line(cls) ?: return@mapNotNull null,
      )
    }
    .sortedBy { it.cls }

/** E14: one row per destination a navigator call can show. */
fun deriveNavigations(index: FactIndex, derived: Derived, screens: List<ScreenFact>): List<NavigationFact> {
  val screenClasses = screens.map { it.cls }.toSet()
  val rows = ArrayList<NavigationFact>()
  for (call in index.calls) {
    if (!call.target.startsWith(NAVIGATOR)) continue
    val op = CallableId.parse(call.target)?.name?.takeIf { it in NAVIGATOR_OPS } ?: continue
    val file = index.fileOf(call.id) ?: continue
    val line = index.lineOf(call.id) ?: continue
    val from = enclosingScreen(index, call.callerDecl, screenClasses)
    val destinations = index.argNodes(call, 0).flatMap { destinations(index, it, screenClasses, HashSet()) }.distinct().sorted()
    if (destinations.isEmpty()) rows += NavigationFact(from, null, call.id, op, file, line)
    destinations.mapTo(rows) { NavigationFact(from, it, call.id, op, file, line) }
  }
  return rows.sortedWith(compareBy({ it.call }, { it.to }))
}

/** The nearest enclosing screen class, or failing that the nearest class or named callable. */
private fun enclosingScreen(index: FactIndex, decl: String, screens: Set<String>): String {
  var current: String? = decl
  while (current != null) {
    if (current in screens) return current
    current = index.decls[current]?.owner
  }
  return index.enclosingClass(decl) ?: index.enclosingNamed(decl) ?: decl
}

/** The screen classes an argument can hold: what it creates, its static type, or what flows into it. */
private fun destinations(index: FactIndex, node: String, screens: Set<String>, seen: MutableSet<String>): List<String> {
  if (!seen.add(node) || seen.size > 200) return emptyList()
  val fact = index.nodes[node] ?: return emptyList()
  if (fact.kind == "lambdaExpr") return emptyList()
  val static = dottedClassOf(fact.type)?.let(index.classByDottedName::get)
  if (static != null && static in screens && (fact.kind == "objectCreation" || !index.has(index.decls.getValue(static), "abstract"))) {
    return listOf(static)
  }
  val target = (index.callsByResult[node]?.target ?: fact.target)?.removeSuffix("#<get>") ?: return emptyList()
  return listOf(target, "$target#<get>#<ret>", "$target#<ret>")
    .flatMap { index.flowsInto[it].orEmpty() }
    .flatMap { destinations(index, it.from, screens, seen) }
    .ifEmpty { listOfNotNull(static) }
}
