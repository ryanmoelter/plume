package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.DeclFact

private const val METRO = "dev/zacsweers/metro/"
private const val METRO_PLUGIN = "dev.zacsweers.metro.compiler"

/** `docs/di/metro.md`; rule numbers in [Provision.evidence] name its sections. */
internal class Metro(private val index: FactIndex) {
  private val options: Map<String, String> =
    index.facts.pluginOptions.filter { it.pluginId == METRO_PLUGIN }.sortedBy { it.module }.associate { it.key to it.value }

  private fun option(name: String): Boolean = options[name] == "true"

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
    )

  /** M17. */
  private fun unwrap(type: String): Unwrapped {
    val (head, args) = genericParts(type)
    val inner = args.singleOrNull()
    if (inner != null) {
      val providers =
        buildSet {
          add("dev.zacsweers.metro.Provider")
          if (option("enable-dagger-runtime-interop")) addAll(listOf("javax.inject.Provider", "jakarta.inject.Provider", "dagger.internal.Provider"))
          if (option("enable-guice-runtime-interop")) add("com.google.inject.Provider")
        }
      val lazies = buildSet {
        add("kotlin.Lazy")
        if (option("enable-dagger-runtime-interop")) add("dagger.Lazy")
      }
      if (head in providers) {
        val (innerHead, innerArgs) = genericParts(inner)
        if (innerHead in lazies && innerArgs.size == 1) return Unwrapped(innerArgs.single(), "providerOfLazy")
        return Unwrapped(inner, "provider")
      }
      if (head in lazies) return Unwrapped(inner, "lazy")
      if (option("enable-suspend-providers") && head in setOf("dev.zacsweers.metro.SuspendProvider", "dev.zacsweers.metro.SuspendLazy")) {
        return Unwrapped(inner, "provider")
      }
    }
    val function = functionType(type)
    if (function != null && function.params.isEmpty()) {
      if (!function.suspend && option("enable-function-providers")) return Unwrapped(function.returns, "function")
      if (function.suspend && option("enable-suspend-providers")) return Unwrapped(function.returns, "function")
    }
    return Unwrapped(type, "direct")
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
    when (options["optional-binding-behavior"] ?: "DEFAULT") {
      "DISABLED" -> false
      "REQUIRE_OPTIONAL_BINDING" -> "default" in param.modifiers && has(param.sym, "OptionalBinding")
      else -> "default" in param.modifiers
    }

  // ---- injectable classes (M5, M15) ----

  private val contributionNames = listOf("ContributesBinding", "ContributesIntoSet", "ContributesIntoMap", "ContributesTo")

  private fun injectConstructor(cls: DeclFact): DeclFact? {
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

  private val injectables: Map<String, Provision> =
    index.classes.filter { it.kind == "class" || it.kind == "object" }.mapNotNull { cls ->
      if (assistedConstructor(cls) != null) return@mapNotNull null
      val ctor = injectConstructor(cls) ?: return@mapNotNull null
      val type = FactIndex.dotted(cls.sym)
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
    val members: List<DeclFact>,
    val provisions: List<Provision>,
    val roots: List<SiteSpec>,
    val parents: List<String>,
    val excludes: Set<String>,
  )

  private fun scopeKeys(annotation: AnnotationFact?): Set<String> =
    (classValues(annotation, "scope", 0) + classValues(annotation, "additionalScopes")).toSet()

  /** M11: what each `Contributes*` annotation contributes, by scope key. */
  private class Contribution(val cls: DeclFact, val annotation: AnnotationFact, val kind: String, val scope: String?)

  private val contributions: List<Contribution> =
    index.classes.flatMap { cls ->
      contributionNames.mapNotNull { name ->
        val annotation = ann(cls.sym, name) ?: return@mapNotNull null
        val scope = classValues(annotation, "scope", 0).firstOrNull()
        Contribution(cls, annotation, name, scope)
      }
    }

  private val replaced: Set<String> =
    contributions.flatMap { classValues(it.annotation, "replaces") }.toSet()

  private fun graphMembers(classes: List<String>): List<DeclFact> =
    classes.flatMap { cls ->
      val own = index.members[cls].orEmpty()
      val companions = own.filter { it.kind == "object" && "companion" in it.modifiers }.flatMap { index.members[it.sym].orEmpty() }
      own + companions
    }.distinctBy { it.sym }

  private fun containers(annotation: AnnotationFact?, extra: List<String>): List<String> =
    (classValues(annotation, "bindingContainers") + extra).flatMap { container ->
      listOf(container) + classValues(ann(container, "BindingContainer"), "includes")
    }.distinct()

  private fun buildGraph(decl: DeclFact, annotation: AnnotationFact?, parents: List<String>): Graph {
    val keys = scopeKeys(annotation)
    val excludes = classValues(annotation, "excludes").toSet()
    val contributed =
      contributions.filter { it.kind == "ContributesTo" && it.scope in keys && it.cls.sym !in excludes && it.cls.sym !in replaced }
    val supertypes = (listOf(decl.sym) + contributed.map { it.cls.sym }).flatMap { index.supertypeClosure(it) }.distinct()
    val containerClasses = containers(annotation, contributed.filter { has(it.cls.sym, "BindingContainer") }.map { it.cls.sym })
    val factory = index.members[decl.sym].orEmpty().firstOrNull { has(it.sym, "DependencyGraph.Factory") || has(it.sym, "GraphExtension.Factory") }
    val factoryParams =
      factory?.let { f -> index.members[f.sym].orEmpty().firstOrNull { it.kind == "fun" && "abstract" in it.modifiers } }
        ?.let { index.parameters(it.sym) }.orEmpty()
    val includedClasses = factoryParams.filter { has(it.sym, "Includes") }.mapNotNull { index.classByDottedName[genericParts(type(it)).first] }
    val members = graphMembers(supertypes + containerClasses + includedClasses.filter { has(it, "BindingContainer") })
    val graphName = FactIndex.dotted(decl.sym)

    val provisions = ArrayList<Provision>()
    val roots = ArrayList<SiteSpec>()
    val concrete = members.filter { "abstract" !in it.modifiers }.map { it.sym }.toSet()
    for (member in members) {
      val overriddenConcretely = index.overriddenBy[member.sym].orEmpty().any { it in concrete }
      when {
        has(member.sym, "Provides") || has("${member.sym}#<get>", "Provides") -> provisions += provides(member)
        has(member.sym, "Binds") -> binds(member)?.let { provisions += it }
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
          val isGraph = has(included, "DependencyGraph")
          for (member in graphMembers(index.supertypeClosure(included))) {
            val accessorLike = "abstract" in member.modifiers && index.parameters(member.sym).isEmpty() && member.kind in setOf("prop", "fun")
            val provider = !isGraph && has(member.sym, "Provides")
            if (!accessorLike && !provider) continue
            provisions +=
              Provision(
                key = DiKey(type(member), qualifier(member.sym)),
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
    // M11: contributed bindings.
    for (contribution in contributions) {
      if (contribution.kind == "ContributesTo" || contribution.scope !in keys) continue
      if (contribution.cls.sym in excludes || contribution.cls.sym in replaced) continue
      contributedBinding(contribution)?.let { provisions += it }
    }
    return Graph(decl, keys, members, provisions, roots, parents, excludes)
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

  private fun multibindingOf(member: DeclFact, declared: String): Triple<String, String?, String?> {
    val sym = member.sym
    return when {
      has(sym, "IntoSet") -> Triple("kotlin.collections.Set<$declared>", "set", null)
      has(sym, "ElementsIntoSet") ->
        Triple("kotlin.collections.Set<${genericParts(declared).second.firstOrNull() ?: declared}>", "set", null)
      has(sym, "IntoMap") -> {
        val key = mapKey(sym)
        Triple("kotlin.collections.Map<${key?.first ?: "?"}, $declared>", "map", key?.second)
      }
      else -> Triple(declared, null, null)
    }
  }

  /** The map key's type and rendered value. */
  private fun mapKey(sym: String): Pair<String, String>? {
    val annotation =
      index.annotationsOf(sym).firstOrNull { ann -> ann.meta.any { it in mapKeyMeta } || ann.annFq in setOf(METRO + "StringKey", METRO + "IntKey", METRO + "ClassKey") }
        ?: return null
    val type =
      when (annotation.annFq) {
        METRO + "StringKey" -> "kotlin.String"
        METRO + "IntKey" -> "kotlin.Int"
        METRO + "ClassKey" -> "kotlin.reflect.KClass<*>"
        else -> FactIndex.dottedName(annotation.annFq)
      }
    return type to (annotation.values.firstOrNull()?.value ?: renderAnnotation(annotation))
  }

  private fun provides(member: DeclFact): Provision {
    val (keyType, multibinding, mapKey) = multibindingOf(member, type(member))
    val sym = member.sym
    return Provision(
      key = DiKey(keyType, qualifier(sym) ?: qualifier("$sym#<get>")),
      provider = sym,
      kind = "provides",
      sites = if (member.kind == "fun") params(sym, skipAssisted = false) else emptyList(),
      scope = scope(sym) ?: scope("$sym#<get>"),
      multibinding = multibinding,
      mapKey = mapKey,
      output = if (member.kind == "fun") "$sym#<ret>" else sym,
      evidence = "M6",
      file = member.file,
      line = index.line(member),
    )
  }

  /** M7. */
  private fun binds(member: DeclFact): Provision? {
    val receiver = receiverType(member.sym) ?: return null
    val declared = type(member)
    val (keyType, multibinding, mapKey) = multibindingOf(member, declared)
    val subtype = index.classByDottedName[genericParts(receiver).first]?.let { index.supertypeClosure(it) }
      ?.any { FactIndex.dotted(it) == genericParts(declared).first } ?: false
    return Provision(
      key = DiKey(keyType, qualifier(member.sym)),
      provider = member.sym,
      kind = "binds",
      sites = listOf(SiteSpec("${member.sym}#<recv>", receiver, qualifier("${member.sym}#<recv>"), member.file, index.line(member))),
      multibinding = multibinding,
      mapKey = mapKey,
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

  private fun contributedBinding(contribution: Contribution): Provision? {
    val cls = contribution.cls
    val bindingArg = contribution.annotation.values.firstOrNull { it.name == "binding" }?.typeArgs?.firstOrNull()
    val directSupers = index.supertypes[cls.sym].orEmpty().map { it.sup }.filter { it != "class:kotlin/Any" }
    val bound =
      bindingArg?.type
        ?: directSupers.singleOrNull()?.let(FactIndex::dotted)
        ?: directSupers.firstOrNull { has(it, "DefaultBinding") }?.let(FactIndex::dotted)
    val ctor = injectConstructor(cls)
    val multibinding =
      when (contribution.kind) {
        "ContributesIntoSet" -> "set"
        "ContributesIntoMap" -> "map"
        else -> null
      }
    val boundType = bound ?: FactIndex.dotted(cls.sym)
    val mapKey = if (multibinding == "map") mapKey(cls.sym) else null
    val keyType =
      when (multibinding) {
        "set" -> "kotlin.collections.Set<$boundType>"
        "map" -> "kotlin.collections.Map<${mapKey?.first ?: "?"}, $boundType>"
        else -> boundType
      }
    val qualifierText =
      bindingArg?.annotations?.firstOrNull { a -> a.meta.any { it in qualifierMeta } }?.let { FactIndex.dottedName(it.value.orEmpty()) }
        ?: qualifier(cls.sym)
    return Provision(
      key = DiKey(keyType, qualifierText),
      provider = ctor?.sym ?: cls.sym,
      kind = "contributedBinding",
      sites = ctor?.let { params(it.sym) + memberSites(cls.sym) }.orEmpty(),
      scope = scope(cls.sym),
      multibinding = multibinding,
      mapKey = mapKey?.second,
      output = ctor?.let { "${it.sym}#<this>" } ?: cls.sym,
      evidence = "M11",
      confidence = if (bound == null) "unsure" else null,
      file = cls.file,
      line = index.line(cls),
    )
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

    val specs =
      graphs.values.map { graph ->
        val name = FactIndex.dotted(graph.decl.sym)
        val explicit = graph.provisions.groupBy { it.key }
        val isExtension = has(graph.decl.sym, "GraphExtension")
        val note =
          when {
            isExtension -> null
            name !in created && creations.none { index.nodes[it.result ?: ""]?.type?.contains(name) == true } -> "no creation site"
            else -> null
          }
        DiGraphSpec(
          name = name,
          variant = variantOf(graph.decl),
          roots = graph.roots,
          provisions = graph.provisions,
          lookup = { key, _ -> lookup(graph, graphs, explicit, key) },
          note = note,
        )
      }
    return resolveGraphs(framework, specs)
  }

  private fun lookup(graph: Graph, graphs: Map<String, Graph>, explicit: Map<DiKey, List<Provision>>, key: DiKey): List<Resolution> {
    explicit[key]?.let { found -> return found.map { Resolution(it) } }
    if (key.qualifier == null) {
      val head = genericParts(key.type).first
      val injectable = injectables[key.type] ?: injectables[head]?.takeIf { key.type == head }
      val factory = assistedFactories[key.type] ?: generatedFactories[key.type]
      val found = injectable ?: factory
      if (found != null && index.classByDottedName[head] !in graph.excludes) return listOf(Resolution(found))
      if (head == "dev.zacsweers.metro.MembersInjector") return emptyList()
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
            upstream = r.upstream ?: (FactIndex.dotted(parent) to p),
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
