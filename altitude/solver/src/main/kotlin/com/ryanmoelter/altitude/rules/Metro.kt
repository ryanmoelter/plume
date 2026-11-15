package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.AnnotationValueFact
import com.ryanmoelter.altitude.facts.DeclFact

private const val METRO = "dev/zacsweers/metro/"
private const val METRO_PLUGIN = "dev.zacsweers.metro.compiler"

/** `docs/di/metro.md`; rule numbers in [Provision.evidence] name its sections. */
internal class Metro(private val index: FactIndex) {
  private val options: Map<String, String> =
    index.facts.pluginOptions.filter { it.pluginId == METRO_PLUGIN }.sortedBy { it.module }.associate { it.key to it.value }

  /** Metro 1.5.1's defaults, for a module whose manifest does not list the option. */
  private val defaults =
    mapOf("contributes-as-inject" to "true", "enable-function-providers" to "true", "optional-binding-behavior" to "DEFAULT")

  private fun option(name: String): Boolean = (options[name] ?: defaults[name]) == "true"

  /** Rows for what Metro would reject at compile time, and for what the analyzer cannot model. */
  private val diagnostics = LinkedHashSet<DiUnresolvedFact>()

  private fun diagnose(
    graph: String?,
    site: String,
    reason: String,
    detail: String,
    type: String? = null,
    file: String? = null,
    line: Int? = null,
  ) {
    diagnostics += DiUnresolvedFact("metro", graph, site, type, null, reason, detail, file, line)
  }

  /** Each Metro annotation name with the foreign annotations interop makes count as it (M20). */
  private val aliases: Map<String, Set<String>> = buildMap {
    fun add(name: String, vararg foreign: String) = put(name, setOf(METRO + name) + foreign)
    val javax = option("interop-include-javax-annotations")
    val jakarta = option("interop-include-jakarta-annotations")
    val dagger = option("interop-include-dagger-annotations") || option("interop-include-hilt-annotations")
    val kotlinInject = option("interop-include-kotlin-inject-annotations")
    val guice = option("interop-include-guice-annotations")
    val anvil = option("interop-include-anvil-annotations")
    fun javaxOr(name: String) =
      listOfNotNull(if (javax) "javax/inject/$name" else null, if (jakarta) "jakarta/inject/$name" else null).toTypedArray()
    add(
      "Inject",
      *javaxOr("Inject"),
      *listOfNotNull(
        if (kotlinInject) "me/tatarka/inject/annotations/Inject" else null,
        if (guice) "com/google/inject/Inject" else null,
      ).toTypedArray(),
    )
    add(
      "Provides",
      *listOfNotNull(
        if (dagger) "dagger/Provides" else null,
        if (kotlinInject) "me/tatarka/inject/annotations/Provides" else null,
        if (guice) "com/google/inject/Provides" else null,
      ).toTypedArray(),
    )
    add("Binds", *listOfNotNull(if (dagger) "dagger/Binds" else null).toTypedArray())
    add("BindingContainer", *listOfNotNull(if (dagger) "dagger/Module" else null).toTypedArray())
    add(
      "DependencyGraph",
      *listOfNotNull(
        if (dagger) "dagger/Component" else null,
        if (kotlinInject) "me/tatarka/inject/annotations/Component" else null,
        if (anvil) "com/squareup/anvil/annotations/MergeComponent" else null,
      ).toTypedArray(),
    )
    add("DependencyGraph.Factory", *listOfNotNull(if (dagger) "dagger/Component.Factory" else null).toTypedArray())
    add("Assisted", *listOfNotNull(if (dagger) "dagger/assisted/Assisted" else null, if (kotlinInject) "me/tatarka/inject/annotations/Assisted" else null, if (guice) "com/google/inject/assistedinject/Assisted" else null).toTypedArray())
    add("AssistedInject", *listOfNotNull(if (dagger) "dagger/assisted/AssistedInject" else null, if (guice) "com/google/inject/assistedinject/AssistedInject" else null).toTypedArray())
    add("AssistedFactory", *listOfNotNull(if (dagger) "dagger/assisted/AssistedFactory" else null).toTypedArray())
    add("IntoSet", *listOfNotNull(if (dagger) "dagger/multibindings/IntoSet" else null, if (kotlinInject) "me/tatarka/inject/annotations/IntoSet" else null).toTypedArray())
    add("ElementsIntoSet", *listOfNotNull(if (dagger) "dagger/multibindings/ElementsIntoSet" else null).toTypedArray())
    add("IntoMap", *listOfNotNull(if (dagger) "dagger/multibindings/IntoMap" else null, if (kotlinInject) "me/tatarka/inject/annotations/IntoMap" else null).toTypedArray())
    add("Multibinds", *listOfNotNull(if (dagger) "dagger/multibindings/Multibinds" else null).toTypedArray())
    add("ContributesTo", *listOfNotNull(if (anvil) "com/squareup/anvil/annotations/ContributesTo" else null).toTypedArray())
    add("ContributesBinding", *listOfNotNull(if (anvil) "com/squareup/anvil/annotations/ContributesBinding" else null).toTypedArray())
    add("ContributesIntoSet", *listOfNotNull(if (anvil) "com/squareup/anvil/annotations/ContributesMultibinding" else null).toTypedArray())
    add("ContributesIntoMap")
    add("ExposeImplBinding")
    add("GraphExtension")
    add("GraphExtension.Factory")
    add("Includes")
    add("OptionalBinding")
    add("GraphPrivate")
    add("DefaultBinding")
  }

  private val qualifierMeta: Set<String> =
    setOf(METRO + "Qualifier", "javax/inject/Qualifier", "jakarta/inject/Qualifier", "me/tatarka/inject/annotations/Qualifier")
  private val scopeMeta: Set<String> =
    setOf(METRO + "Scope", "javax/inject/Scope", "jakarta/inject/Scope", "me/tatarka/inject/annotations/Scope")
  private val mapKeyMeta: Set<String> = setOf(METRO + "MapKey", "dagger/MapKey")

  private fun ann(sym: String, name: String): AnnotationFact? {
    val names = aliases[name] ?: setOf(METRO + name)
    return index.annotationsOf(sym).firstOrNull { it.annFq in names }
  }

  private fun anns(sym: String, name: String): List<AnnotationFact> {
    val names = aliases[name] ?: setOf(METRO + name)
    return index.annotationsOf(sym).filter { it.annFq in names }
  }

  private fun has(sym: String, name: String): Boolean = ann(sym, name) != null

  private fun qualifier(sym: String): String? =
    index.renderedWithMeta(sym, qualifierMeta).filter { !it.startsWith("dev.zacsweers.metro.Qualifier") }.minOrNull()

  private fun scope(sym: String): String? =
    index.annotationsOf(sym)
      .filter { ann -> ann.meta.any { it in scopeMeta } || ann.annFq == METRO + "SingleIn" }
      .map(::renderAnnotation)
      .minOrNull()

  private fun type(decl: DeclFact): String = decl.typeExpanded ?: decl.type.orEmpty()

  private fun classValues(annotation: AnnotationFact?, name: String, position: Int = -1): List<String> {
    if (annotation == null) return emptyList()
    val value =
      annotation.values.firstOrNull { it.name == name }
        ?: annotation.values.getOrNull(position)?.takeIf { position >= 0 && it.name == null }
        ?: return emptyList()
    val all = if (value.kind == "array") value.elements else listOf(value)
    return all.mapNotNull { it.cls }
  }

  val framework =
    DiFramework(
      name = "metro",
      unwrap = ::unwrap,
      typeKind = { index.typeKindOf(it) },
      wrapperFor = { unwrapped, resolution ->
        if (unwrapped.wrapper == "direct" && resolution?.provision?.kind == "assistedFactory") "assistedFactory"
        else unwrapped.wrapper
      },
      explainMissing = { key ->
        if (key.qualifier == null && key.type in hiddenImpls) {
          "generate-contribution-providers hides the implementation type; inject its bound type or add @ExposeImplBinding"
        } else {
          null
        }
      },
    )

  private val providerTypes: Set<String> =
    buildSet {
      add("dev.zacsweers.metro.Provider")
      if (option("enable-dagger-runtime-interop")) addAll(listOf("javax.inject.Provider", "jakarta.inject.Provider", "dagger.internal.Provider"))
      if (option("enable-guice-runtime-interop")) add("com.google.inject.Provider")
    }

  private val lazyTypes: Set<String> =
    buildSet {
      add("kotlin.Lazy")
      if (option("enable-dagger-runtime-interop")) add("dagger.Lazy")
    }

  /** One wrapper layer around [type], or null when [type] is not wrapped. */
  private fun peel(type: String): Unwrapped? {
    val (head, args) = genericParts(type)
    val inner = args.singleOrNull()
    if (inner != null) {
      if (head in providerTypes) return Unwrapped(inner, "provider")
      if (head in lazyTypes) return Unwrapped(inner, "lazy")
      if (option("enable-suspend-providers")) {
        if (head == "dev.zacsweers.metro.SuspendProvider") return Unwrapped(inner, "provider")
        if (head == "dev.zacsweers.metro.SuspendLazy") return Unwrapped(inner, "lazy")
      }
    }
    val function = functionType(type)
    if (function != null && function.params.isEmpty()) {
      if (!function.suspend && option("enable-function-providers")) return Unwrapped(function.returns, "function")
      if (function.suspend && option("enable-suspend-providers")) return Unwrapped(function.returns, "function")
    }
    return null
  }

  /** Every wrapper layer around [type], outermost first, and the type inside them. */
  private fun peelAll(type: String): Pair<List<String>, String> {
    val layers = ArrayList<String>()
    var current = type
    while (true) {
      val next = peel(current) ?: break
      layers += next.wrapper
      current = next.type
    }
    return layers to current
  }

  private fun wrapperName(layers: List<String>): String =
    when {
      layers.isEmpty() -> "direct"
      layers.take(2) == listOf("provider", "lazy") -> "providerOfLazy"
      else -> layers.first()
    }

  /** M17. A map multibinding unwraps its values too: `Map<K, Provider<V>>` requests `Map<K, V>`. */
  private fun unwrap(type: String): Unwrapped {
    val (layers, inner) = peelAll(type)
    val (head, args) = genericParts(inner)
    if (head == "kotlin.collections.Map" && args.size == 2) {
      val (valueLayers, value) = peelAll(args[1])
      if (valueLayers.isNotEmpty()) {
        return Unwrapped("kotlin.collections.Map<${args[0]}, $value>", wrapperName(layers.ifEmpty { valueLayers }))
      }
    }
    return Unwrapped(inner, wrapperName(layers))
  }

  private fun params(owner: String, skipAssisted: Boolean = true): List<SiteSpec> =
    index.parameters(owner)
      .filter { !(skipAssisted && has(it.sym, "Assisted")) }
      .map { param ->
        SiteSpec(
          site = param.sym,
          type = type(param),
          qualifier = qualifier(param.sym),
          file = param.file,
          line = index.line(param),
          hasDefault = optional(param),
        )
      }

  /** M18. */
  private fun optional(param: DeclFact): Boolean =
    when (options["optional-binding-behavior"] ?: defaults.getValue("optional-binding-behavior")) {
      "DISABLED" -> false
      "REQUIRE_OPTIONAL_BINDING" -> "default" in param.modifiers && has(param.sym, "OptionalBinding")
      else -> "default" in param.modifiers
    }

  // ---- injectable classes (M5, M15) ----

  private val contributionNames = listOf("ContributesBinding", "ContributesIntoSet", "ContributesIntoMap", "ContributesTo")

  private fun injectConstructor(cls: DeclFact): DeclFact? {
    if (cls.kind != "class" && cls.kind != "object" || "abstract" in cls.modifiers || "sealed" in cls.modifiers) return null
    val ctors = index.constructors(cls.sym)
    ctors.firstOrNull { has(it.sym, "Inject") }?.let { return it }
    val contributesAsInject =
      option("contributes-as-inject") && contributionNames.take(3).any { has(cls.sym, it) }
    if (has(cls.sym, "Inject") || (contributesAsInject && ctors.size <= 1)) return ctors.firstOrNull()
    return null
  }

  private fun assistedConstructor(cls: DeclFact): DeclFact? {
    val ctors = index.constructors(cls.sym)
    ctors.firstOrNull { has(it.sym, "AssistedInject") }?.let { return it }
    return if (has(cls.sym, "AssistedInject")) ctors.firstOrNull() else null
  }

  /**
   * With `generate-contribution-providers`, Metro binds a contributed class only as its bound type,
   * unless the class carries `ExposeImplBinding`.
   */
  private val hiddenImpls: Set<String> =
    if (!option("generate-contribution-providers")) emptySet()
    else index.classes
      .filter { cls -> contributionNames.take(3).any { has(cls.sym, it) } && !has(cls.sym, "ExposeImplBinding") }
      .map { FactIndex.dotted(it.sym) }
      .toSet()

  private val injectables: Map<String, Provision> =
    index.classes.filter { it.kind == "class" || it.kind == "object" }.mapNotNull { cls ->
      if (assistedConstructor(cls) != null) return@mapNotNull null
      val ctor = injectConstructor(cls) ?: return@mapNotNull null
      val type = FactIndex.dotted(cls.sym)
      if (type in hiddenImpls) return@mapNotNull null
      type to
        Provision(
          key = DiKey(type),
          provider = ctor.sym,
          kind = "constructorInject",
          sites = params(ctor.sym) + memberSites(cls.sym),
          scope = scope(cls.sym),
          always = false,
          output = "${ctor.sym}#<this>",
          evidence = "M5",
          file = cls.file,
          line = index.line(cls),
        )
    }.toMap()

  /** M19: a top-level `Inject` function, which Metro turns into a class named after it. */
  private val functionInjections: List<Provision> =
    index.decls.values
      .filter { it.kind == "fun" && it.owner?.startsWith("file:") == true && has(it.sym, "Inject") }
      .sortedBy { it.sym }
      .mapNotNull { function ->
        if (!option("enable-top-level-function-injection")) {
          diagnose(
            null,
            function.sym,
            "unsupportedFeature",
            "Inject on a top-level function needs enable-top-level-function-injection",
            file = function.file,
            line = index.line(function),
          )
          return@mapNotNull null
        }
        val pkg = function.sym.substringAfter(':').substringBefore('(').substringBeforeLast('/', "").replace('/', '.')
        val type = listOf(pkg, function.name.replaceFirstChar(Char::uppercase)).filter { it.isNotEmpty() }.joinToString(".")
        Provision(
          key = DiKey(type),
          provider = function.sym,
          kind = "functionInject",
          sites = params(function.sym),
          evidence = "M19",
          file = function.file,
          line = index.line(function),
        )
      }

  /** M16. */
  private fun memberSites(cls: String): List<SiteSpec> =
    index.members[cls].orEmpty()
      .filter { (it.kind == "prop" || it.kind == "fun") && has(it.sym, "Inject") }
      .flatMap { member ->
        if (member.kind == "prop") {
          listOf(SiteSpec(member.sym, type(member), qualifier(member.sym), member.file, index.line(member)))
        } else {
          params(member.sym)
        }
      }

  private val assistedFactories: Map<String, Provision> =
    index.classes.filter { has(it.sym, "AssistedFactory") }.mapNotNull { factory ->
      val create = index.members[factory.sym].orEmpty().firstOrNull { it.kind == "fun" && "abstract" in it.modifiers }
      val target = create?.let { index.classByDottedName[genericParts(type(it)).first] }?.let { index.decls[it] }
      val ctor = target?.let { assistedConstructor(it) ?: index.constructors(it.sym).firstOrNull() }
      val type = FactIndex.dotted(factory.sym)
      type to
        Provision(
          key = DiKey(type),
          provider = factory.sym,
          kind = "assistedFactory",
          sites = ctor?.let { params(it.sym) }.orEmpty(),
          assistedTarget = ctor?.sym,
          always = false,
          evidence = "M15",
          confidence = if (ctor == null) "unsure" else null,
          file = factory.file,
          line = index.line(factory),
        )
    }.toMap()

  /** M15: an `AssistedInject` class with no factory in source, when Metro generates one. */
  private val generatedFactories: Map<String, Provision> =
    if (!option("generate-assisted-factories")) emptyMap()
    else index.classes.mapNotNull { cls ->
      val ctor = assistedConstructor(cls) ?: return@mapNotNull null
      val nested = index.members[cls.sym].orEmpty().any { has(it.sym, "AssistedFactory") }
      val referenced = assistedFactories.values.any { it.assistedTarget == ctor.sym }
      if (nested || referenced) return@mapNotNull null
      val type = FactIndex.dotted(cls.sym) + ".Factory"
      type to
        Provision(
          key = DiKey(type),
          provider = "${cls.sym}.Factory",
          kind = "assistedFactory",
          sites = params(ctor.sym),
          assistedTarget = ctor.sym,
          always = false,
          evidence = "M15",
          confidence = "unsure",
          note = "generated factory",
          file = cls.file,
          line = index.line(cls),
        )
    }.toMap()

  // ---- graphs ----

  private class Graph(
    val decl: DeclFact,
    val scopeKeys: Set<String>,
    /** The rendered scope annotations a binding of this graph may carry (M8). */
    val acceptedScopes: Set<String>,
    val members: List<DeclFact>,
    val provisions: List<Provision>,
    val roots: List<SiteSpec>,
    val parents: List<String>,
    val excludes: Set<String>,
  ) {
    val name: String = FactIndex.dotted(decl.sym)
  }

  private fun scopeKeys(annotation: AnnotationFact?): Set<String> =
    (classValues(annotation, "scope", 0) + classValues(annotation, "additionalScopes")).toSet()

  /** M11: one `Contributes*` annotation; a class may carry several, as they are repeatable. */
  private class Contribution(val cls: DeclFact, val annotation: AnnotationFact, val kind: String, val scope: String?)

  private val contributions: List<Contribution> =
    index.classes.flatMap { cls ->
      contributionNames.flatMap { name ->
        anns(cls.sym, name).map { annotation ->
          Contribution(cls, annotation, name, classValues(annotation, "scope", 0).firstOrNull())
        }
      }
    }

  /** The contributions a graph with [keys] receives: `excludes` first, then `replaces` among what is left. */
  private fun visibleContributions(keys: Set<String>, excludes: Set<String>): List<Contribution> {
    val candidates = contributions.filter { it.scope in keys && it.cls.sym !in excludes }
    val replaced = candidates.flatMap { classValues(it.annotation, "replaces") }.toSet()
    return candidates.filter { it.cls.sym !in replaced }
  }

  private fun graphMembers(classes: List<String>): List<DeclFact> =
    classes.flatMap { cls ->
      val own = index.members[cls].orEmpty()
      val companions = own.filter { it.kind == "object" && "companion" in it.modifiers }.flatMap { index.members[it.sym].orEmpty() }
      own + companions
    }.distinctBy { it.sym }

  /** Binding containers and, transitively, the containers they include. */
  private fun containers(roots: List<String>): List<String> {
    val seen = LinkedHashSet<String>()
    val queue = ArrayDeque(roots)
    while (queue.isNotEmpty()) {
      val next = queue.removeFirst()
      if (seen.add(next)) queue += classValues(ann(next, "BindingContainer"), "includes")
    }
    return seen.toList()
  }

  private fun acceptedScopes(decl: DeclFact, keys: Set<String>): Set<String> =
    keys.flatMap { listOf("dev.zacsweers.metro.SingleIn(${FactIndex.dotted(it)})", FactIndex.dotted(it)) }.toSet() +
      index.annotationsOf(decl.sym).filter { ann -> ann.meta.any { it in scopeMeta } }.map(::renderAnnotation)

  private fun buildGraph(decl: DeclFact, annotation: AnnotationFact?, parents: List<String>): Graph {
    val keys = scopeKeys(annotation)
    val excludes = classValues(annotation, "excludes").toSet()
    val visible = visibleContributions(keys, excludes)
    val contributed = visible.filter { it.kind == "ContributesTo" }
    val supertypes = (listOf(decl.sym) + contributed.map { it.cls.sym }).flatMap { index.supertypeClosure(it) }.distinct()
    val factory = index.members[decl.sym].orEmpty().firstOrNull { has(it.sym, "DependencyGraph.Factory") || has(it.sym, "GraphExtension.Factory") }
    val factoryParams =
      factory?.let { f -> index.members[f.sym].orEmpty().firstOrNull { it.kind == "fun" && "abstract" in it.modifiers } }
        ?.let { index.parameters(it.sym) }.orEmpty()
    val includedClasses = factoryParams.filter { has(it.sym, "Includes") }.mapNotNull { index.classByDottedName[genericParts(type(it)).first] }
    val containerClasses =
      containers(
        classValues(annotation, "bindingContainers") +
          contributed.filter { has(it.cls.sym, "BindingContainer") }.map { it.cls.sym } +
          includedClasses.filter { has(it, "BindingContainer") }
      ).filter { it !in excludes }
    val members = graphMembers(supertypes + containerClasses)
    val graphName = FactIndex.dotted(decl.sym)
    val accepted = acceptedScopes(decl, keys)

    val provisions = ArrayList<Provision>()
    val roots = ArrayList<SiteSpec>()
    val concrete = members.filter { "abstract" !in it.modifiers }.map { it.sym }.toSet()
    for (member in members) {
      val overriddenConcretely = index.overriddenBy[member.sym].orEmpty().any { it in concrete }
      when {
        has(member.sym, "Provides") || has("${member.sym}#<get>", "Provides") -> provides(graphName, member)?.let { provisions += it }
        has(member.sym, "Binds") -> binds(graphName, member)?.let { provisions += it }
        has(member.sym, "Multibinds") -> provisions += multibinds(member)
        "abstract" !in member.modifiers || overriddenConcretely -> Unit
        member.kind == "prop" && "receiver" !in member.modifiers -> roots += accessor(member)
        member.kind == "fun" -> {
          val ps = index.parameters(member.sym)
          when {
            ps.isEmpty() && member.type != "kotlin.Unit" -> roots += accessor(member)
            ps.size == 1 && (member.type == null || member.type == "kotlin.Unit") -> {
              val target = index.classByDottedName[genericParts(type(ps.single())).first]
              if (target != null) roots += memberSites(target)
            }
          }
        }
      }
    }
    // M10: the graph binds its own type and the graph-shaped interfaces it implements.
    for (sup in index.supertypeClosure(decl.sym)) {
      val supDecl = index.decls[sup] ?: continue
      if (sup != decl.sym && supDecl.kind != "interface") continue
      provisions +=
        Provision(
          key = DiKey(FactIndex.dotted(sup)),
          provider = decl.sym,
          kind = "graph",
          evidence = "M10",
          file = decl.file,
          line = index.line(decl),
        )
    }
    // M3.
    for (param in factoryParams) {
      when {
        has(param.sym, "Provides") ->
          provisions +=
            Provision(
              key = DiKey(type(param), qualifier(param.sym)),
              provider = param.sym,
              kind = "instance",
              output = param.sym,
              evidence = "M3",
              file = param.file,
              line = index.line(param),
            )
        has(param.sym, "Includes") -> {
          val included = index.classByDottedName[genericParts(type(param)).first] ?: continue
          if (has(included, "BindingContainer")) continue
          val isGraph = has(included, "DependencyGraph")
          for (member in graphMembers(index.supertypeClosure(included))) {
            // A graph exposes only its accessors; any other class exposes every public no-argument member.
            val accessorLike = index.parameters(member.sym).isEmpty() && member.kind in setOf("prop", "fun") &&
              "private" !in member.modifiers && "receiver" !in member.modifiers && member.type != "kotlin.Unit" &&
              (!isGraph || "abstract" in member.modifiers)
            val provider = !isGraph && has(member.sym, "Provides")
            if (!accessorLike && !provider) continue
            provisions +=
              Provision(
                key = DiKey(type(member), qualifier(member.sym) ?: qualifier("${member.sym}#<get>")),
                provider = member.sym,
                kind = "includedAccessor",
                output = if (member.kind == "fun") "${member.sym}#<ret>" else member.sym,
                evidence = "M3",
                file = member.file,
                line = index.line(member),
              )
          }
        }
      }
    }
    // M11: contributed bindings, after `priority` (M11a) drops the losers.
    val contributedBindings = visible.filter { it.kind != "ContributesTo" }.mapNotNull { contributedBinding(graphName, it) }
    provisions += byPriority(contributedBindings).map { it.second }
    for (provision in provisions) {
      val scope = provision.scope ?: continue
      if (scope in accepted) continue
      diagnose(
        graphName,
        provision.provider,
        "scopeMismatch",
        "$scope is not a scope of this graph",
        provision.key.type,
        provision.file,
        provision.line,
      )
    }
    mapKeyCollisions(graphName, provisions)
    return Graph(decl, keys, accepted, members, provisions, roots, parents, excludes)
  }

  /**
   * M11a: among contributions of one key (and one map key), only the highest `priority` survives.
   * A tie stays, so the graph reports the duplicate as Metro does.
   */
  private fun byPriority(bindings: List<Pair<Int, Provision>>): List<Pair<Int, Provision>> =
    bindings.groupBy { (_, p) -> Triple(p.key, p.multibinding, if (p.multibinding == "set") p.provider else p.mapKey) }
      .flatMap { (_, group) ->
        val top = group.maxOf { it.first }
        group.filter { it.first == top }
      }

  /** Two entries of one map with the same key: Metro rejects the graph. */
  private fun mapKeyCollisions(graph: String, provisions: List<Provision>) {
    provisions.filter { it.multibinding == "map" && it.kind != "multibinds" }
      .groupBy { Triple(it.key, it.mapKey, it.parent) }
      .filter { it.value.size > 1 }
      .forEach { (key, group) ->
        val first = group.minBy { it.provider }
        diagnose(
          graph,
          first.provider,
          "duplicateMapKey",
          "map key ${key.second} is bound by ${group.map { it.provider }.sorted().joinToString(",")}",
          key.first.type,
          first.file,
          first.line,
        )
      }
  }

  private fun accessor(member: DeclFact): SiteSpec =
    SiteSpec(
      site = member.sym,
      type = type(member),
      qualifier = qualifier(member.sym) ?: qualifier("${member.sym}#<get>"),
      file = member.file,
      line = index.line(member),
      hasDefault = has(member.sym, "OptionalBinding"),
      location = if (member.kind == "prop") "${member.sym}#<get>" else "${member.sym}#<ret>",
    )

  /** The collection key a declaration contributes to, or null with a diagnostic when it has no map key. */
  private class Multibinding(val type: String, val kind: String?, val mapKey: String?)

  private fun multibindingOf(graph: String, member: DeclFact, declared: String, implicitClass: String?): Multibinding? {
    val sym = member.sym
    return when {
      has(sym, "IntoSet") -> Multibinding("kotlin.collections.Set<$declared>", "set", null)
      has(sym, "ElementsIntoSet") ->
        Multibinding("kotlin.collections.Set<${genericParts(declared).second.firstOrNull() ?: declared}>", "set", null)
      has(sym, "IntoMap") -> {
        val key = mapKey(index.annotationsOf(sym) + index.annotationsOf("$sym#<get>"), implicitClass)
        if (key == null) {
          diagnose(graph, sym, "missingMapKey", "IntoMap without a map key annotation", declared, member.file, index.line(member))
          return null
        }
        Multibinding("kotlin.collections.Map<${key.first}, $declared>", "map", key.second)
      }
      else -> Multibinding(declared, null, null)
    }
  }

  /**
   * The map key's type and rendered value. A key annotation unwraps to its single member unless it
   * sets `unwrapValue = false`. `ClassKey` without a value names [implicitClass].
   */
  private fun mapKey(annotations: List<AnnotationFact>, implicitClass: String?): Pair<String, String>? {
    val annotation =
      annotations.firstOrNull { ann -> ann.meta.any { it in mapKeyMeta } || ann.annFq in setOf(METRO + "StringKey", METRO + "IntKey", METRO + "ClassKey") }
        ?: return null
    return mapKey(annotation.annFq, annotation.values, implicitClass) { renderAnnotation(annotation) }
  }

  private fun mapKey(annFq: String, values: List<AnnotationValueFact>, implicitClass: String?, render: () -> String): Pair<String, String>? {
    val value = values.firstOrNull()
    when (annFq) {
      METRO + "StringKey" -> return "kotlin.String" to (value?.value ?: return null)
      METRO + "IntKey" -> return "kotlin.Int" to (value?.value ?: return null)
      METRO + "ClassKey" -> {
        val cls = value?.value?.takeIf { it != "kotlin.Nothing" } ?: implicitClass ?: return null
        return "kotlin.reflect.KClass<*>" to cls
      }
    }
    val keyClass = "class:$annFq"
    val unwrap = index.annotationsOf(keyClass).firstOrNull { it.annFq in mapKeyMeta }
      ?.values?.firstOrNull { it.name == "unwrapValue" }?.value != "false"
    if (!unwrap) return FactIndex.dottedName(annFq) to render()
    val member = index.members[keyClass].orEmpty().firstOrNull { it.kind == "prop" }
    val memberType = member?.let(::type) ?: value?.let(::constantType) ?: return null
    return memberType to (value?.value ?: return null)
  }

  /** The type of a map key annotation's member, read from its value when the annotation class is a library's. */
  private fun constantType(value: AnnotationValueFact): String? =
    when (value.kind) {
      "enum" -> value.value?.removePrefix("enumEntry:")?.substringBeforeLast('.')?.replace('/', '.')
      "class" -> "kotlin.reflect.KClass<*>"
      "const" -> {
        val text = value.value.orEmpty()
        when {
          text.startsWith("\"") -> "kotlin.String"
          text.startsWith("'") -> "kotlin.Char"
          text == "true" || text == "false" -> "kotlin.Boolean"
          text.endsWith("L") -> "kotlin.Long"
          text.toIntOrNull() != null -> "kotlin.Int"
          else -> null
        }
      }
      else -> null
    }

  private fun provides(graph: String, member: DeclFact): Provision? {
    val multibinding = multibindingOf(graph, member, type(member), null) ?: return null
    val sym = member.sym
    return Provision(
      key = DiKey(multibinding.type, qualifier(sym) ?: qualifier("$sym#<get>")),
      provider = sym,
      kind = "provides",
      sites = if (member.kind == "fun") params(sym, skipAssisted = false) else emptyList(),
      scope = scope(sym) ?: scope("$sym#<get>"),
      multibinding = multibinding.kind,
      mapKey = multibinding.mapKey,
      output = if (member.kind == "fun") "$sym#<ret>" else sym,
      evidence = "M6",
      file = member.file,
      line = index.line(member),
    )
  }

  /** M7. */
  private fun binds(graph: String, member: DeclFact): Provision? {
    val receiver = receiverType(member.sym) ?: return null
    val declared = type(member)
    val multibinding = multibindingOf(graph, member, declared, genericParts(receiver).first) ?: return null
    val subtype = index.classByDottedName[genericParts(receiver).first]?.let { index.supertypeClosure(it) }
      ?.any { FactIndex.dotted(it) == genericParts(declared).first } ?: false
    return Provision(
      key = DiKey(multibinding.type, qualifier(member.sym)),
      provider = member.sym,
      kind = "binds",
      sites = listOf(SiteSpec("${member.sym}#<recv>", receiver, qualifier("${member.sym}#<recv>"), member.file, index.line(member))),
      multibinding = multibinding.kind,
      mapKey = multibinding.mapKey,
      output = "${member.sym}#<recv>",
      evidence = "M7",
      confidence = if (subtype) null else "unsure",
      file = member.file,
      line = index.line(member),
    )
  }

  private fun multibinds(member: DeclFact): Provision =
    Provision(
      key = DiKey(type(member), qualifier(member.sym)),
      provider = member.sym,
      kind = "multibinds",
      multibinding = if (type(member).startsWith("kotlin.collections.Map")) "map" else "set",
      evidence = "M12",
      file = member.file,
      line = index.line(member),
    )

  /** The receiver type in a callable ID, `…@a/b/C(…)` or `…@a/b/C`. */
  private fun receiverType(sym: String): String? {
    val head = sym.substringAfter(':')
    val at = head.indexOf('@').takeIf { it >= 0 } ?: return null
    var depth = 0
    val text = head.substring(at + 1)
    for ((i, c) in text.withIndex()) {
      when (c) {
        '<' -> depth++
        '>' -> depth--
        '(', '#' -> if (depth == 0) return dottedIdType(text.substring(0, i))
      }
    }
    return dottedIdType(text)
  }

  /** `priority` on `ContributesBinding` and `ContributesIntoMap`; Anvil's `rank` under interop. */
  private fun priority(annotation: AnnotationFact): Int =
    annotation.values.firstOrNull { it.name == "priority" || (it.name == "rank" && annotation.annFq.startsWith("com/squareup/anvil/")) }
      ?.value?.toIntOrNull() ?: Int.MIN_VALUE

  /** The type `DefaultBinding<T>` names on the nearest supertype that carries it. */
  private fun defaultBinding(cls: String): String? {
    for (sup in index.supertypeClosure(cls).drop(1)) {
      val annotation = ann(sup, "DefaultBinding") ?: continue
      return annotation.typeArgs.firstOrNull()?.type ?: FactIndex.dotted(sup)
    }
    return null
  }

  /** M11, with the contribution's `priority`. */
  private fun contributedBinding(graph: String, contribution: Contribution): Pair<Int, Provision>? {
    val cls = contribution.cls
    val annotation = contribution.annotation
    val bindingArg = annotation.values.firstOrNull { it.name == "binding" }?.typeArgs?.firstOrNull()
    val directSupers = index.supertypes[cls.sym].orEmpty().map { it.sup }.filter { it != "class:kotlin/Any" }
    val bound =
      bindingArg?.type
        ?: directSupers.singleOrNull()?.let(FactIndex::dotted)
        ?: defaultBinding(cls.sym)
    val ctor = injectConstructor(cls)
    if (ctor == null && cls.kind != "object") {
      diagnose(
        graph,
        cls.sym,
        "notInjectable",
        "${contribution.kind} on a class with no injectable constructor: add Inject to one constructor, or make it an object",
        FactIndex.dotted(cls.sym),
        cls.file,
        index.line(cls),
      )
      return null
    }
    val multibinding =
      when (contribution.kind) {
        "ContributesIntoSet" -> "set"
        "ContributesIntoMap" -> "map"
        else -> null
      }
    if (bound == null) {
      diagnose(
        graph,
        cls.sym,
        "ambiguousBoundType",
        "${contribution.kind} on a class with ${directSupers.size} supertypes and no binding<T>() or DefaultBinding",
        FactIndex.dotted(cls.sym),
        cls.file,
        index.line(cls),
      )
      return null
    }
    val boundType: String = bound
    val mapKey =
      if (multibinding != "map") null
      else bindingArg?.annotations?.firstNotNullOfOrNull { a ->
        a.takeIf { a.meta.any { it in mapKeyMeta } }?.let { mapKey(it.value.orEmpty(), it.elements, FactIndex.dotted(cls.sym)) { renderValue(a) } }
      } ?: mapKey(index.annotationsOf(cls.sym), FactIndex.dotted(cls.sym))
    if (multibinding == "map" && mapKey == null) {
      diagnose(graph, cls.sym, "missingMapKey", "ContributesIntoMap without a map key annotation", boundType, cls.file, index.line(cls))
      return null
    }
    val keyType =
      when (multibinding) {
        "set" -> "kotlin.collections.Set<$boundType>"
        "map" -> "kotlin.collections.Map<${mapKey!!.first}, $boundType>"
        else -> boundType
      }
    val qualifierText =
      bindingArg?.annotations?.firstOrNull { a -> a.meta.any { it in qualifierMeta } }?.let(::renderValue)
        ?: qualifier(cls.sym)
    val provision =
      Provision(
        key = DiKey(keyType, qualifierText),
        provider = ctor?.sym ?: cls.sym,
        kind = "contributedBinding",
        sites = ctor?.let { params(it.sym) + memberSites(cls.sym) }.orEmpty(),
        scope = scope(cls.sym),
        multibinding = multibinding,
        mapKey = mapKey?.second,
        output = ctor?.let { "${it.sym}#<this>" } ?: cls.sym,
        evidence = "M11",
        file = cls.file,
        line = index.line(cls),
      )
    return priority(annotation) to provision
  }

  fun derive(): DiResult {
    val graphDecls = index.classes.filter { has(it.sym, "DependencyGraph") }
    val graphs = LinkedHashMap<String, Graph>()
    for (decl in graphDecls) graphs[decl.sym] = buildGraph(decl, ann(decl.sym, "DependencyGraph"), emptyList())
    // M13: an extension's parents are the graphs that expose it or its factory.
    val extensions = index.classes.filter { has(it.sym, "GraphExtension") }
    repeat(extensions.size) {
      for (ext in extensions) {
        val factory = index.members[ext.sym].orEmpty().firstOrNull { has(it.sym, "GraphExtension.Factory") }
        val exposed = setOfNotNull(FactIndex.dotted(ext.sym), factory?.let { FactIndex.dotted(it.sym) })
        val factoryScope = factory?.let { classValues(ann(it.sym, "ContributesTo"), "scope", 0).firstOrNull() }
        val parents =
          graphs.values.filter { g ->
            g.decl.sym != ext.sym &&
              (g.roots.any { genericParts(unwrap(it.type).type).first in exposed } ||
                (factory != null && factory.sym in index.supertypeClosure(g.decl.sym)) ||
                (factoryScope != null && factoryScope in g.scopeKeys))
          }.map { it.decl.sym }
        val existing = graphs[ext.sym]
        if (existing == null || existing.parents != parents) graphs[ext.sym] = buildGraph(ext, ann(ext.sym, "GraphExtension"), parents)
      }
    }

    val creations = index.calls.filter { it.target.startsWith("fun:dev/zacsweers/metro/createGraph") }
    val created = creations.mapNotNull { call -> index.nodes[call.result ?: ""]?.type?.let { genericParts(it).first } }.toSet()
    for (call in index.calls.filter { it.target.startsWith("fun:dev/zacsweers/metro/createDynamicGraph") }) {
      diagnose(
        index.nodes[call.result ?: ""]?.type,
        call.id,
        "unsupportedFeature",
        "createDynamicGraph replaces bindings with containers passed at run time; links of this graph ignore them",
        file = index.fileOf(call.id),
        line = index.lineOf(call.id),
      )
    }
    emptyMultibindings(graphs)

    // M13: a parent binds each extension it exposes, and the extension's factory.
    val exposedBy = HashMap<String, MutableList<Provision>>()
    for (ext in extensions) {
      val graph = graphs[ext.sym] ?: continue
      val factory = index.members[ext.sym].orEmpty().firstOrNull { has(it.sym, "GraphExtension.Factory") }
      for (parent in graph.parents) {
        for (decl in listOfNotNull(ext, factory)) {
          exposedBy.getOrPut(parent) { ArrayList() } +=
            Provision(
              key = DiKey(FactIndex.dotted(decl.sym)),
              provider = decl.sym,
              kind = if (decl === ext) "graphExtension" else "graphExtensionFactory",
              evidence = "M13",
              file = decl.file,
              line = index.line(decl),
            )
        }
      }
    }

    val specs =
      graphs.values.map { graph ->
        val provisions = graph.provisions + exposedBy[graph.decl.sym].orEmpty()
        val explicit = provisions.groupBy { it.key }
        val isExtension = has(graph.decl.sym, "GraphExtension")
        val note =
          when {
            isExtension -> null
            graph.name !in created && creations.none { index.nodes[it.result ?: ""]?.type?.contains(graph.name) == true } -> "no creation site"
            else -> null
          }
        DiGraphSpec(
          name = graph.name,
          variant = variantOf(graph.decl),
          roots = graph.roots,
          provisions = provisions + functionInjections,
          lookup = { key, _ -> lookup(graph, graphs, explicit, key) },
          note = note,
        )
      }
    val result = resolveGraphs(framework, specs)
    val unresolved = (result.unresolved + diagnostics).distinct().sortedWith(compareBy({ it.graph }, { it.site }, { it.reason }))
    return DiResult(result.bindings, result.sites, unresolved, result.flows)
  }

  /** M12: a `Multibinds` declaration without `allowEmpty = true` that no element fills. */
  private fun emptyMultibindings(graphs: Map<String, Graph>) {
    for (graph in graphs.values) {
      for (declaration in graph.provisions.filter { it.kind == "multibinds" }) {
        val allowEmpty = ann(declaration.provider, "Multibinds")?.values?.firstOrNull { it.name == "allowEmpty" }?.value == "true"
        if (allowEmpty) continue
        val chain = ancestors(graph, graphs)
        val filled = chain.any { g -> g.provisions.any { it.key == declaration.key && it.kind != "multibinds" } }
        if (!filled) {
          diagnose(
            graph.name,
            declaration.provider,
            "emptyMultibinding",
            "no element fills this multibinding and it does not set allowEmpty = true",
            declaration.key.type,
            declaration.file,
            declaration.line,
          )
        }
      }
    }
  }

  /** [graph] and every graph above it, nearest first. */
  private fun ancestors(graph: Graph, graphs: Map<String, Graph>): List<Graph> {
    val seen = LinkedHashMap<String, Graph>()
    val queue = ArrayDeque(listOf(graph))
    while (queue.isNotEmpty()) {
      val next = queue.removeFirst()
      if (seen.put(next.decl.sym, next) != null) continue
      next.parents.mapNotNullTo(queue) { graphs[it] }
    }
    return seen.values.toList()
  }

  private fun lookup(graph: Graph, graphs: Map<String, Graph>, explicit: Map<DiKey, List<Provision>>, key: DiKey): List<Resolution> {
    explicit[key]?.let { found -> return found.map { Resolution(it) } }
    functionInjections.filter { it.key == key }.takeIf { it.isNotEmpty() }?.let { found -> return found.map { Resolution(it) } }
    if (key.qualifier == null) {
      val head = genericParts(key.type).first
      val injectable = injectables[key.type] ?: injectables[head]?.takeIf { key.type == head }
      val factory = assistedFactories[key.type] ?: generatedFactories[key.type]
      val found = (injectable ?: factory)?.takeIf { index.classByDottedName[head] !in graph.excludes }
      if (found != null) {
        val scope = found.scope
        // M8: a scoped class lives in the graph that owns its scope, which may be an ancestor.
        val ownedAbove = scope != null && scope !in graph.acceptedScopes &&
          ancestors(graph, graphs).drop(1).any { scope in it.acceptedScopes }
        if (!ownedAbove) {
          if (scope != null && scope !in graph.acceptedScopes) {
            diagnose(graph.name, found.provider, "scopeMismatch", "no graph from here up declares $scope", key.type, found.file, found.line)
          }
          return listOf(Resolution(found))
        }
      }
      if (head == "dev.zacsweers.metro.MembersInjector") {
        val target = genericParts(key.type).second.singleOrNull()?.let { index.classByDottedName[genericParts(it).first] }
        if (target != null) {
          return listOf(
            Resolution(
              Provision(
                key = key,
                provider = target,
                kind = "membersInjector",
                sites = memberSites(target),
                always = false,
                evidence = "M16",
                file = index.decls[target]?.file,
                line = index.line(index.decls[target]),
              )
            )
          )
        }
      }
    }
    for (parent in graph.parents) {
      val parentGraph = graphs[parent] ?: continue
      val inherited = lookup(parentGraph, graphs, parentGraph.provisions.groupBy { it.key }, key)
      if (inherited.isEmpty()) continue
      return inherited
        .filter { !has(it.provision.provider, "GraphPrivate") }
        .map { r ->
          val p = r.provision
          Resolution(
            Provision(
              key = p.key, provider = p.provider, kind = "parentGraph", scope = p.scope, multibinding = p.multibinding,
              mapKey = p.mapKey, parent = FactIndex.dotted(parent), always = false, output = p.output, evidence = "M14",
              file = p.file, line = p.line,
            ),
            upstream = r.upstream.ifEmpty { listOf(FactIndex.dotted(parent) to p) },
          )
        }
    }
    return emptyList()
  }
}

/** A graph or component whose name starts with `Fake` is the test double of a production one. */
internal fun variantOf(decl: DeclFact): String =
  when {
    decl.name.startsWith("Fake") -> "fake"
    decl.file?.contains("/src/test/") == true || decl.file?.contains("/src/androidTest/") == true -> "test"
    else -> "production"
  }
