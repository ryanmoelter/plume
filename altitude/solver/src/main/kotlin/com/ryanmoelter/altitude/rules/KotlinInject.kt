package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.DeclFact

private const val KI = "me/tatarka/inject/annotations/"

/** `docs/di/kotlin-inject.md`; rule numbers in [Provision.evidence] name its sections. */
internal class KotlinInject(private val index: FactIndex) {
  private fun has(sym: String, name: String): Boolean = index.hasAnnotation(sym, KI + name)

  private fun hasOnDeclOrGetter(sym: String, name: String): Boolean = has(sym, name) || has("$sym#<get>", name)

  private val scopeMeta = setOf(KI + "Scope")
  private val qualifierMeta = setOf(KI + "Qualifier")

  private fun scope(sym: String): String? =
    (index.renderedWithMeta(sym, scopeMeta) + index.renderedWithMeta("$sym#<get>", scopeMeta)).minOrNull()

  private fun qualifier(sym: String): String? =
    (index.renderedWithMeta(sym, qualifierMeta) + index.renderedWithMeta("$sym#<get>", qualifierMeta)).minOrNull()

  /** K8: aliases are distinct keys, so the type stays as written. */
  private fun type(decl: DeclFact): String = decl.type.orEmpty()

  val framework =
    DiFramework(
      name = "kotlin-inject",
      unwrap = ::unwrap,
      typeKind = { index.typeKindOf(it) },
    )

  /** K10, K11. */
  private fun unwrap(type: String): Unwrapped {
    val (head, args) = genericParts(type)
    if (head == "kotlin.Lazy" && args.size == 1) return Unwrapped(args.single(), "lazy")
    val function = functionType(type)
    if (function != null && !function.suspend) return Unwrapped(function.returns, "function")
    return Unwrapped(type, "direct")
  }

  private fun params(owner: String): List<SiteSpec> =
    index.parameters(owner)
      .filter { !has(it.sym, "Assisted") }
      .map { param ->
        SiteSpec(
          site = param.sym,
          type = type(param),
          qualifier = qualifier(param.sym),
          file = param.file,
          line = index.line(param),
          hasDefault = "default" in param.modifiers,
        )
      }

  /** K5. */
  private val injectables: Map<String, Provision> =
    index.classes.filter { it.kind == "class" || it.kind == "object" }.mapNotNull { cls ->
      val ctors = index.constructors(cls.sym)
      val ctor = ctors.firstOrNull { has(it.sym, "Inject") } ?: ctors.firstOrNull()?.takeIf { has(cls.sym, "Inject") }
      ctor ?: return@mapNotNull null
      val type = FactIndex.dotted(cls.sym)
      type to
        Provision(
          key = DiKey(type),
          provider = ctor.sym,
          kind = "constructorInject",
          sites = params(ctor.sym),
          scope = scope(cls.sym),
          always = false,
          output = "${ctor.sym}#<this>",
          evidence = "K5",
          file = cls.file,
          line = index.line(cls),
        )
    }.toMap()

  private class Parent(val type: String, val cls: String, val param: DeclFact)

  private class Component(
    val decl: DeclFact,
    val name: String,
    val scopes: Set<String>,
    val provisions: List<Provision>,
    val roots: List<SiteSpec>,
    val parents: List<Parent>,
    /** What a child sees of this component through a parent of its class type: accessor key → accessor ID. */
    val accessors: Map<DiKey, DeclFact>,
  )

  private fun componentScopes(cls: String): Set<String> =
    index.supertypeClosure(cls).flatMap { index.renderedWithMeta(it, scopeMeta) }.toSet()

  private fun isAccessor(member: DeclFact): Boolean =
    "abstract" in member.modifiers &&
      !hasOnDeclOrGetter(member.sym, "Provides") &&
      when (member.kind) {
        "prop" -> "receiver" !in member.modifiers
        "fun" -> index.parameters(member.sym).isEmpty() && member.type != null && member.type != "kotlin.Unit"
        else -> false
      }

  /** Accessors of a class or interface and its supertypes that no concrete member overrides. */
  private fun accessorsOf(cls: String): List<DeclFact> {
    val members = index.supertypeClosure(cls).flatMap { index.members[it].orEmpty() }
    val concrete = members.filter { "abstract" !in it.modifiers }.map { it.sym }.toSet()
    return members.filter { isAccessor(it) && index.overriddenBy[it.sym].orEmpty().none { o -> o in concrete } }
  }

  private fun buildComponent(decl: DeclFact): Component {
    val closure = index.supertypeClosure(decl.sym)
    val members = closure.flatMap { index.members[it].orEmpty() }.distinctBy { it.sym }
    val provisions = ArrayList<Provision>()
    val ctor = index.constructors(decl.sym).firstOrNull()
    val parents = ArrayList<Parent>()
    val ctorParams = ctor?.let { index.parameters(it.sym) }.orEmpty()
    for (param in ctorParams) {
      val prop = index.decls["prop:${decl.sym.removePrefix("class:")}.${param.name}"]
      if (has(param.sym, "Component") || (prop != null && has(prop.sym, "Component"))) {
        val cls = index.classByDottedName[genericParts(type(param)).first]
        if (cls != null) parents += Parent(type(param), cls, param)
      }
    }
    for (member in members) {
      val sym = member.sym
      if (!hasOnDeclOrGetter(sym, "Provides")) continue
      val intoSet = hasOnDeclOrGetter(sym, "IntoSet")
      val intoMap = hasOnDeclOrGetter(sym, "IntoMap")
      val declared = type(member)
      val keyType =
        when {
          intoSet -> "kotlin.collections.Set<$declared>"
          intoMap -> genericParts(declared).second.let { "kotlin.collections.Map<${it.getOrNull(0)}, ${it.getOrNull(1)}>" }
          else -> declared
        }
      val receiver = member.kind == "prop" && "receiver" in member.modifiers
      val isInstance = member.kind == "prop" && !receiver && ctorParams.any { it.name == member.name } && member.owner == decl.sym
      val sites =
        when {
          member.kind == "fun" -> params(sym)
          receiver -> listOf(SiteSpec("$sym#<recv>", receiverType(sym) ?: "", null, member.file, index.line(member)))
          else -> emptyList()
        }
      provisions +=
        Provision(
          key = DiKey(keyType, qualifier(sym)),
          provider = sym,
          kind = if (isInstance) "instance" else "provides",
          sites = sites,
          scope = scope(sym),
          multibinding = if (intoSet) "set" else if (intoMap) "map" else null,
          output = if (member.kind == "fun") "$sym#<ret>" else if (receiver) "$sym#<recv>" else sym,
          evidence = if (isInstance) "K3" else if (receiver) "K7" else "K6",
          file = member.file,
          line = index.line(member),
        )
    }
    val accessors = accessorsOf(decl.sym)
    val roots =
      accessors.map { member ->
        SiteSpec(
          site = member.sym,
          type = type(member),
          qualifier = qualifier(member.sym),
          file = member.file,
          line = index.line(member),
          location = if (member.kind == "prop") "${member.sym}#<get>" else "${member.sym}#<ret>",
        )
      }
    val visible = LinkedHashMap<DiKey, DeclFact>()
    for (accessor in accessors) visible.putIfAbsent(DiKey(type(accessor), qualifier(accessor.sym)), accessor)
    return Component(decl, FactIndex.dotted(decl.sym), componentScopes(decl.sym), provisions, roots, parents, visible)
  }

  private fun receiverType(sym: String): String? {
    val head = sym.substringAfter(':')
    val at = head.indexOf('@').takeIf { it >= 0 } ?: return null
    val text = head.substring(at + 1)
    var depth = 0
    for ((i, c) in text.withIndex()) {
      when (c) {
        '<' -> depth++
        '>' -> depth--
        '(', '#' -> if (depth == 0) return dottedIdType(text.substring(0, i))
      }
    }
    return dottedIdType(text)
  }

  fun derive(): DiResult {
    val components = index.classes.filter { has(it.sym, "Component") && it.kind == "class" }.associate { it.sym to buildComponent(it) }
    if (components.isEmpty()) return DiResult()
    val specs =
      components.values.map { component ->
        val own = component.provisions.groupBy { it.key }
        DiGraphSpec(
          name = component.name,
          variant = variantOf(component.decl),
          roots = component.roots,
          provisions = component.provisions,
          lookup = { key, wrapper -> lookup(component, components, own, key, wrapper) },
        )
      }
    return resolveGraphs(framework, specs)
  }

  private fun lookup(
    component: Component,
    components: Map<String, Component>,
    own: Map<DiKey, List<Provision>>,
    key: DiKey,
    wrapper: String,
  ): List<Resolution> {
    val local = own[key].orEmpty().map { Resolution(it) }
    if (key.type.startsWith("kotlin.collections.Set<")) {
      return local + component.parents.flatMap { parentResolutions(component, it, components, key) }
    }
    if (local.isNotEmpty()) return local
    val injectable = if (key.qualifier == null) injectables[key.type] else null
    if (injectable?.scope != null && injectable.scope in component.scopes) return listOf(Resolution(injectable))
    for (parent in component.parents) {
      val found = parentResolutions(component, parent, components, key)
      if (found.isNotEmpty()) return found
    }
    if (injectable != null) return listOf(Resolution(injectable))
    return emptyList()
  }

  /**
   * The components that may stand behind a parent typed as an interface. Source cannot say which one
   * a caller passes, so every component of the child's variant that implements it counts.
   */
  private fun implementors(child: Component, cls: String, components: Map<String, Component>): List<Component> {
    val all = components.values.filter { cls in index.supertypeClosure(it.decl.sym) && it.decl.sym != child.decl.sym }
    return all.filter { variantOf(it.decl) == variantOf(child.decl) }.ifEmpty { all }
  }

  /** K4: what a key resolves to through one parent component, recursively. */
  private fun parentResolutions(child: Component, parent: Parent, components: Map<String, Component>, key: DiKey): List<Resolution> {
    val parentComponent = components[parent.cls]
    val parentName = FactIndex.dotted(parent.cls)
    fun row(provider: DeclFact, scope: String?, upstream: List<Pair<String, Provision>>): Resolution =
      Resolution(
        Provision(
          key = key,
          provider = provider.sym,
          kind = "parentComponent",
          scope = scope,
          parent = parentName,
          always = false,
          output = upstream.firstOrNull()?.second?.output ?: if (provider.kind == "prop") "${provider.sym}#<get>" else "${provider.sym}#<ret>",
          evidence = "K4",
          file = provider.file,
          line = index.line(provider),
        ),
        upstream,
      )
    if (parentComponent == null) {
      val behind = implementors(child, parent.cls, components)
      val upstream = behind.flatMap { c -> c.provisions.filter { it.key == key }.map { c.name to it } }
      accessorsOf(parent.cls).firstOrNull { DiKey(type(it), qualifier(it.sym)) == key }?.let { accessor ->
        return listOf(row(accessor, null, upstream))
      }
      val provided =
        index.supertypeClosure(parent.cls).flatMap { index.members[it].orEmpty() }
          .filter { it.kind == "fun" && hasOnDeclOrGetter(it.sym, "Provides") && DiKey(type(it), qualifier(it.sym)) == key }
      return provided.map { row(it, scope(it.sym), upstream) }
    }
    parentComponent.accessors[key]?.let { accessor ->
      val upstream = parentComponent.provisions.firstOrNull { it.key == key } ?: injectables[key.type]
      return listOf(row(accessor, null, listOfNotNull(upstream?.let { parentName to it })))
    }
    val provided = parentComponent.provisions.filter { it.key == key }
    if (provided.isNotEmpty()) {
      return provided.map { p -> row(index.decls.getValue(p.provider), p.scope, listOf(parentName to p)) }
    }
    val injectable = injectables[key.type]
    if (injectable?.scope != null && injectable.scope in parentComponent.scopes) {
      return listOf(Resolution(injectable, listOf(parentName to injectable)))
    }
    for (grand in parentComponent.parents) {
      val found = parentResolutions(parentComponent, grand, components, key)
      if (found.isNotEmpty()) return found
    }
    return emptyList()
  }
}
