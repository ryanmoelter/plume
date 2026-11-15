package com.ryanmoelter.altitude.export

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** `altitude/docs/export.md` documents every field. */
const val EXPORT_SCHEMA_VERSION = 1

@Serializable
data class AltitudeExport(
  val schema: String = "altitude-export",
  val schemaVersion: Int = EXPORT_SCHEMA_VERSION,
  val meta: ExportMeta,
  /** Every source file; a site elsewhere is `<index into files>:<line>`. */
  val files: List<String>,
  val containers: List<ContainerOut>,
  val features: List<FeatureOut>,
  val nodes: List<NodeOut>,
  val edges: List<EdgeOut>,
  val cells: List<CellOut>,
  val entrypoints: List<EntryOut>,
  val boundaries: List<BoundaryOut>,
  val bindings: List<BindingOut>,
  val navigations: List<NavigationOut>,
  val bundles: Bundles,
  val patterns: Patterns,
  val traces: List<TraceOut>,
)

@Serializable
data class ExportMeta(
  val target: String,
  val gitSha: String? = null,
  val gitDirty: Boolean? = null,
  val factsSchemaVersion: Int,
  /** The constants the derivations use, so a page can say what it is showing. */
  val params: Map<String, Int>,
  val layers: List<String>,
  val counts: Map<String, Int>,
  /** Node detail lives in this file, next to the export, when it is split out. */
  val detailFile: String? = null,
)

@Serializable
data class Size(val loc: Int, val decls: Int, val nodes: Int = 0)

@Serializable
data class ContainerOut(
  val id: String,
  val kind: String,
  val parent: String? = null,
  val name: String,
  val qualified: String,
  val depth: Int,
  val size: Size,
)

@Serializable
data class FeatureOut(
  val id: String,
  val module: String,
  val pkg: String,
  val containers: List<String>,
  val size: Size,
  val entrypoints: Int = 0,
)

@Serializable
data class Dist(
  val min: Int,
  /** The median over the node's named callables that reach it, rounded down. */
  val median: Int,
  /** How many of the node's named callables reach it. */
  val reaching: Int,
)

@Serializable
data class UiEvidence(
  val composableFuns: Int = 0,
  val funs: Int = 0,
  /** Cell reads made in composable code. */
  val uiReads: Int = 0,
  /** Lambdas a composable passes as an event callback. */
  val eventLambdas: Int = 0,
)

@Serializable
data class CellRefs(
  val owned: List<Int> = emptyList(),
  val writes: List<Int> = emptyList(),
  val reads: List<Int> = emptyList(),
)

@Serializable
data class Placement(
  /** Call hops from the node down to each boundary kind. */
  val down: Map<String, Dist> = emptyMap(),
  /** Call hops from each entry point kind up to the node. */
  val up: Map<String, Dist> = emptyMap(),
  val boundaryCalls: Map<String, Int> = emptyMap(),
  val entryKinds: List<String> = emptyList(),
  val cells: CellRefs = CellRefs(),
  val ui: UiEvidence = UiEvidence(),
  val dataType: Boolean = false,
)

@Serializable
data class Reach(
  /** Indices into `entrypoints`. */
  val entries: List<Int> = emptyList(),
  /** The distinct containers of those entry points, by kind: `module`, `feature`. */
  val byContainer: Map<String, List<String>> = emptyMap(),
)

@Serializable
data class FanIn(
  val nodes: Int = 0,
  /** Features of the nodes with an edge into this one, other than its own. */
  val features: List<String> = emptyList(),
  val layers: List<Int> = emptyList(),
)

@Serializable
data class Infrastructure(val score: Double, val flag: Boolean, val why: List<String> = emptyList())

@Serializable
data class Misplaced(val container: String, val reachedOnlyFrom: String)

@Serializable
data class Role(val role: String, val evidence: JsonObject)

@Serializable
data class NodeOut(
  val id: String,
  val kind: String,
  val name: String,
  val container: String,
  val feature: String,
  val file: String,
  val line: Int,
  val generated: Boolean = false,
  /** In a test source set, under a preview annotation, or a fake; production never runs it. */
  val staged: Boolean = false,
  val modifiers: List<String> = emptyList(),
  val size: Size,
  val layer: Int? = null,
  val layerWhy: String,
  val placement: Placement,
  val reach: Reach,
  val fanIn: FanIn,
  val infrastructure: Infrastructure,
  val misplaced: Misplaced? = null,
  val roles: List<Role> = emptyList(),
)

@Serializable
data class EdgeOut(
  val from: String,
  val to: String,
  val kind: String,
  val count: Int,
  val sites: List<String>,
  /** The `via` of each call edge, or the `kind` of each value flow, with its count. */
  val detail: Map<String, Int> = emptyMap(),
  val crossesLayer: Boolean = false,
  val crossesFeature: Boolean = false,
)

@Serializable
data class CellAccessOut(val node: String, val op: String, val count: Int, val context: String)

@Serializable
data class CellOut(
  val id: String,
  val holder: String? = null,
  val mechanism: String,
  val owner: String? = null,
  /** `property` when a class or file property holds it, else `local`. */
  val scope: String,
  /** The class the cell's element type names, when it is in the sources. */
  val elementType: String? = null,
  val writers: List<CellAccessOut> = emptyList(),
  val readers: List<CellAccessOut> = emptyList(),
)

@Serializable
data class EntryOut(
  val kind: String,
  val sym: String,
  val attrs: Map<String, String> = emptyMap(),
  val node: String? = null,
  val feature: String? = null,
  val file: String? = null,
  val line: Int? = null,
)

@Serializable
data class BoundaryOut(
  val system: String,
  val kind: String,
  val op: String,
  val target: String,
  val caller: String,
  val node: String? = null,
  val access: String? = null,
  val label: String? = null,
  val operation: String? = null,
  val method: String? = null,
  val path: String? = null,
  val file: String,
  val line: Int,
)

@Serializable
data class BindingOut(
  val framework: String,
  val graph: String,
  val graphNode: String? = null,
  val type: String,
  val qualifier: String? = null,
  val provider: String,
  val providerNode: String? = null,
  val kind: String,
  val scope: String? = null,
  val variant: String,
  val reachable: Boolean,
  val file: String? = null,
  val line: Int? = null,
)

@Serializable
data class NavigationOut(val from: String, val to: String? = null, val op: String, val file: String, val line: Int)

@Serializable
data class WrapOut(val inner: String, val outer: String, val count: Int, val sites: List<String>)

@Serializable
data class ArgGroupOut(
  val call: String,
  val from: String,
  val to: String,
  val callee: String,
  /** Parameter names, in order. */
  val params: List<String>,
  /** The node of each argument's static type, when it is in the sources. */
  val types: List<String?>,
)

@Serializable
data class Bundles(val wraps: List<WrapOut>, val argGroups: List<ArgGroupOut>)

@Serializable
data class PatternVector(val scope: String, val counts: Map<String, Int>, val label: String? = null, val because: List<String> = emptyList())

@Serializable
data class LoopOut(
  /** The cell composable code reads. */
  val cell: Int,
  /** The cell the event path writes; the same as [cell], or one whose values flow into it. */
  val written: Int,
  val owner: String? = null,
  val ownerRole: String,
  val reader: String,
  val writer: String,
  /** Call hops from the reading node's event lambda to the write. */
  val hops: Int,
)

@Serializable
data class Patterns(val target: PatternVector, val features: List<PatternVector>, val loops: List<LoopOut>)

@Serializable
data class TraceHopOut(
  val from: String,
  val to: String,
  /** A call edge's `via`, or a flow edge's kind. */
  val kind: String,
  val site: String? = null,
  val rule: String? = null,
  val fromNode: String? = null,
  val toNode: String? = null,
  /** Index into `edges` of the aggregated edge this hop is part of. */
  val edge: Int? = null,
  /** How many objects deep the traced value is after the hop: +1 on `partOf`, -1 on `memberOf`. */
  val wrapDepth: Int = 0,
)

@Serializable
data class TraceLegOut(val from: String, val to: String, val hops: List<TraceHopOut>, val nodePath: List<String>)

@Serializable
data class TraceOut(
  val name: String,
  val query: String,
  val comment: String? = null,
  /** `call` or `value`. */
  val kind: String,
  val legs: List<TraceLegOut>,
  /** Whether every hop equals the corresponding hop of the golden trace text. */
  val matchesGolden: Boolean? = null,
  val note: String? = null,
)
