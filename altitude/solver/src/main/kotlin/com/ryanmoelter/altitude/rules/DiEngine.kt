package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.FlowFact

/** A binding key: a rendered type, dotted, plus a rendered qualifier. */
internal data class DiKey(val type: String, val qualifier: String? = null)

/** A value a graph must supply. [location] is the value location the supplied value flows into. */
internal class SiteSpec(
  val site: String,
  val type: String,
  val qualifier: String? = null,
  val file: String?,
  val line: Int?,
  val hasDefault: Boolean = false,
  val location: String = site,
)

/** One way a graph can supply a key. */
internal class Provision(
  val key: DiKey,
  val provider: String,
  val kind: String,
  val sites: List<SiteSpec> = emptyList(),
  val scope: String? = null,
  val multibinding: String? = null,
  val mapKey: String? = null,
  val assistedTarget: String? = null,
  val parent: String? = null,
  /** A row even when nothing needs it, with `reachable: false`. */
  val always: Boolean = true,
  /** The value location that holds what the provider yields. */
  val output: String? = null,
  val evidence: String,
  val confidence: String? = null,
  val note: String? = null,
  val file: String?,
  val line: Int?,
) {
  val identity: String
    get() = "$kind|$provider|${key.type}|${key.qualifier}|$multibinding|$mapKey|$parent"
}

/**
 * What a site resolves to in one graph: rows of this graph, each with the binding of another graph
 * it hands off to, as a child component does to its parent.
 */
internal class Resolution(val provision: Provision, val upstream: List<Pair<String, Provision>> = emptyList())

/** A request after its wrapper is removed. */
internal class Unwrapped(val type: String, val wrapper: String)

internal class DiGraphSpec(
  val name: String,
  val variant: String,
  val roots: List<SiteSpec>,
  /** Bindings that get a row whether or not something needs them, when [Provision.always]. */
  val provisions: List<Provision>,
  val lookup: (DiKey, String) -> List<Resolution>,
  val note: String? = null,
)

internal class DiFramework(
  val name: String,
  val unwrap: (String) -> Unwrapped,
  val typeKind: (String) -> String,
  /** A `wrapper` that names the requested type itself, such as an assisted factory. */
  val wrapperFor: (Unwrapped, Resolution?) -> String = { u, _ -> u.wrapper },
)

/**
 * Resolves every graph to a fixpoint over site→provider links, starting from the roots. A binding
 * reached through a child's resolution is reached in its own graph too, so its sites resolve there.
 */
internal fun resolveGraphs(framework: DiFramework, graphs: List<DiGraphSpec>): DiResult {
  val byName = graphs.associateBy { it.name }
  val reached = graphs.associate { it.name to LinkedHashMap<String, Provision>() }
  val queue = ArrayDeque<Pair<String, SiteSpec>>()
  val sites = ArrayList<InjectionSiteFact>()
  val unresolved = ArrayList<DiUnresolvedFact>()
  val flows = ArrayList<FlowFact>()
  val seenSites = HashSet<String>()

  fun reach(graph: String, provision: Provision) {
    val map = reached[graph] ?: return
    if (map.putIfAbsent(provision.identity, provision) != null) return
    for (site in provision.sites) queue += graph to site
  }

  for (graph in graphs) for (root in graph.roots) queue += graph.name to root
  while (queue.isNotEmpty()) {
    val (graphName, site) = queue.removeFirst()
    if (!seenSites.add("$graphName|${site.site}|${site.type}")) continue
    val graph = byName.getValue(graphName)
    val unwrapped = framework.unwrap(site.type)
    val key = DiKey(unwrapped.type, site.qualifier)
    val found = graph.lookup(key, unwrapped.wrapper)
    for (resolution in found) {
      reach(graphName, resolution.provision)
      for ((up, provision) in resolution.upstream) reach(up, provision)
      val output = resolution.upstream.firstOrNull()?.second?.output ?: resolution.provision.output
      if (output != null) flows += FlowFact(output, site.location, "di", site.site)
    }
    val note =
      when {
        found.isEmpty() && site.hasDefault -> "default value"
        else -> null
      }
    if (found.isEmpty() && !site.hasDefault) {
      unresolved +=
        DiUnresolvedFact(
          framework = framework.name,
          graph = graphName,
          site = site.site,
          type = key.type,
          qualifier = key.qualifier,
          reason = "missingBinding",
          file = site.file,
          line = site.line,
        )
    }
    val keyed = found.filter { it.provision.multibinding == null }
    if (keyed.size > 1) {
      unresolved +=
        DiUnresolvedFact(
          framework = framework.name,
          graph = graphName,
          site = site.site,
          type = key.type,
          qualifier = key.qualifier,
          reason = "duplicateBinding",
          detail = keyed.joinToString(",") { it.provision.provider },
          file = site.file,
          line = site.line,
        )
    }
    sites +=
      InjectionSiteFact(
        framework = framework.name,
        graph = graphName,
        site = site.site,
        type = key.type,
        qualifier = key.qualifier,
        wrapper = framework.wrapperFor(unwrapped, found.firstOrNull()),
        provider = InjectionSiteFact.providerOf(found.map { it.provision.provider }.distinct().sorted()),
        typeKind = framework.typeKind(if (unwrapped.wrapper == "function") site.type else key.type),
        variant = graph.variant,
        note = note,
        file = site.file,
        line = site.line,
      )
  }

  val bindings = ArrayList<BindingFact>()
  for (graph in graphs) {
    val hit = reached.getValue(graph.name)
    val listed = graph.provisions.filter { it.always }
    val rows = (listed.associateBy { it.identity } + hit).values
    for (provision in rows) {
      bindings +=
        BindingFact(
          framework = framework.name,
          graph = graph.name,
          type = provision.key.type,
          qualifier = provision.key.qualifier,
          provider = provision.provider,
          kind = provision.kind,
          scope = provision.scope,
          reachable = provision.identity in hit,
          multibinding = provision.multibinding,
          mapKey = provision.mapKey,
          assistedTarget = provision.assistedTarget,
          parent = provision.parent,
          variant = graph.variant,
          confidence = provision.confidence,
          note = provision.note ?: graph.note,
          evidence = provision.evidence,
          file = provision.file,
          line = provision.line,
        )
    }
  }
  return DiResult(
    bindings = bindings.distinct().sortedWith(compareBy({ it.graph }, { it.type }, { it.provider }, { it.kind })),
    sites = sites.distinct().sortedWith(compareBy({ it.graph }, { it.site }, { it.type })),
    unresolved = unresolved.distinct().sortedWith(compareBy({ it.graph }, { it.site }, { it.reason })),
    flows = flows.distinct().sortedWith(compareBy({ it.from }, { it.to }, { it.at })),
  )
}

/** Splits [text] at each top-level [separator], outside `<>` and `()`. */
internal fun splitTopLevel(text: String, separator: Char = ','): List<String> {
  val parts = ArrayList<String>()
  var depth = 0
  var start = 0
  for ((i, c) in text.withIndex()) {
    when (c) {
      '<', '(' -> depth++
      ')' -> depth--
      '>' -> if (i == 0 || text[i - 1] != '-') depth--
      separator -> if (depth == 0) {
        parts += text.substring(start, i).trim()
        start = i + 1
      }
    }
  }
  val last = text.substring(start).trim()
  if (last.isNotEmpty() || parts.isNotEmpty()) parts += last
  return parts
}

/** `a.B<C, D>` as `a.B` and its arguments; a type without arguments has none. */
internal fun genericParts(type: String): Pair<String, List<String>> {
  if (type.startsWith("(")) return type to emptyList()
  val open = type.indexOf('<')
  if (open < 0 || !type.endsWith(">")) return type to emptyList()
  return type.substring(0, open) to splitTopLevel(type.substring(open + 1, type.length - 1))
}

/** The parameter types and return type of a non-nullable function type such as `(A, B) -> C`. */
internal class FunctionType(val params: List<String>, val returns: String, val suspend: Boolean)

internal fun functionType(type: String): FunctionType? {
  val suspend = type.startsWith("suspend ")
  val text = type.removePrefix("suspend ")
  if (!text.startsWith("(")) return null
  var depth = 0
  for ((i, c) in text.withIndex()) {
    when (c) {
      '(', '<' -> depth++
      ')', '>' -> {
        if (c == '>' && i > 0 && text[i - 1] == '-') continue
        depth--
        if (depth == 0 && c == ')') {
          val rest = text.substring(i + 1)
          if (!rest.startsWith(" -> ")) return null
          val params = text.substring(1, i).let { if (it.isBlank()) emptyList() else splitTopLevel(it) }
          return FunctionType(params, rest.removePrefix(" -> "), suspend)
        }
      }
    }
  }
  return null
}

/** A type as an ID writes it (`a/b/C<d/E,f/G>`) in the dotted form rows use (`a.b.C<d.E, f.G>`). */
internal fun dottedIdType(idType: String): String = idType.replace('/', '.').replace(",", ", ")

internal fun FactIndex.typeKindOf(type: String): String {
  if (functionType(type) != null) return "function"
  val head = genericParts(type.removeSuffix("?")).first
  val decl = classByDottedName[head]?.let { decls[it] } ?: return "library"
  return when {
    decl.kind == "interface" -> "interface"
    decl.kind == "object" -> "object"
    "abstract" in decl.modifiers || "sealed" in decl.modifiers -> "abstract"
    else -> "class"
  }
}

internal fun FactIndex.declLine(decl: DeclFact?): Int? = line(decl)

/** The annotations on [sym] whose class carries [meta], rendered with their arguments. */
internal fun FactIndex.renderedWithMeta(sym: String, meta: Set<String>): List<String> =
  annotationsOf(sym).filter { ann -> ann.meta.any { it in meta } || ann.annFq in meta }.map(::renderAnnotation)

internal fun renderAnnotation(ann: com.ryanmoelter.altitude.facts.AnnotationFact): String {
  val name = FactIndex.dottedName(ann.annFq)
  if (ann.values.isEmpty()) return name
  return "$name(${ann.values.joinToString(", ") { renderValue(it) }})"
}

private fun renderValue(value: com.ryanmoelter.altitude.facts.AnnotationValueFact): String =
  when (value.kind) {
    "array" -> "[" + value.elements.joinToString(", ") { renderValue(it) } + "]"
    "annotation" ->
      FactIndex.dottedName(value.value.orEmpty()) +
        (if (value.elements.isEmpty()) "" else "(" + value.elements.joinToString(", ") { renderValue(it) } + ")")
    else -> value.value.orEmpty()
  }

/** The constructor Altitude treats as primary: the annotated one, else the one declared first. */
internal fun FactIndex.constructors(cls: String): List<DeclFact> =
  members[cls].orEmpty().filter { it.kind == "ctor" }.sortedWith(compareBy({ line(it) ?: 0 }, { it.sym }))
