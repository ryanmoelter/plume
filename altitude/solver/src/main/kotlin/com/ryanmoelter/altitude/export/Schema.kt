package com.ryanmoelter.altitude.export

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** `altitude/docs/export.md` documents every field. */
const val EXPORT_SCHEMA_VERSION = 3

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class AltitudeExport(
  @EncodeDefault val schema: String = "altitude-export",
  @EncodeDefault val schemaVersion: Int = EXPORT_SCHEMA_VERSION,
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
  /** Members and member edges live in this file, next to the export. */
  val membersFile: String? = null,
  /** Branch trees live in this file, next to the export. */
  val branchesFile: String? = null,
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
  /** Why the node is staged: `test`, `preview` or `fake`. */
  val nonProduction: String? = null,
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
  val fromMember: String? = null,
  val toMember: String? = null,
  /** Index into the members file's `edges`. */
  val memberEdge: Int? = null,
  /** A `cha` call's candidates. */
  val candidates: Int? = null,
  /** The function values that reach a `fnValue` invoke. */
  val fanOut: Int? = null,
  /** Flow edges that carry the invoked value to a `fnValue` invoke. */
  val witness: Int? = null,
  /** Further call sites between the same caller and callee. */
  val otherSites: Int = 0,
  /** An `invoke` hop's role and the library callable that runs it. */
  val role: String? = null,
  val invoker: String? = null,
  /** The callee runs later than the call: a cell hop, or an invoke whose model runs it asynchronously. */
  val async: Boolean = false,
  /** Index into `cells`: the cell a `cell` hop joins, or the cell whose contents a flow hop writes. */
  val cell: Int? = null,
  /** Index into `cells` of the cell whose contents a flow hop reads. */
  val fromCell: Int? = null,
  /** A `cell` hop's write and read operations, and the derived streams between them. */
  val cellOp: String? = null,
  val through: Int = 0,
  val construction: Boolean = false,
  val projection: Boolean = false,
  val container: Boolean = false,
  /** The containers a `contentOf` hop may step out of, when more than one. */
  val containerChoices: Int? = null,
  val heldBy: Boolean = false,
  /** The values that meet at the hop's target, when more than one. */
  val fanIn: Int? = null,
  /** The hop reads a container's contents with nothing on the path to say which container. */
  val anyContainer: Boolean = false,
  /** The class property the hop leaves, which stands for that property of every instance. */
  val anyInstanceOf: String? = null,
  /** The property a `memberOf` hop reads. */
  val property: String? = null,
  /** The parameter a `partOf` hop passes the value as. */
  val field: String? = null,
  /** A `memberOf` hop that reads another field than the one the path built the object with. */
  val fieldMismatch: Boolean = false,
  /** The hop lands in code production never runs. */
  val nonProduction: Boolean = false,
  /** What the hop adds to the leg's skeleton. */
  val landmark: String? = null,
)

/** A value path's cost, compared field by field in this order. */
@Serializable
data class CostOut(val anyInstanceReads: Int = 0, val stagedHops: Int = 0, val conflation: Int = 0, val derivedHops: Int = 0, val length: Int = 0)

@Serializable
data class TraceLegOut(
  val from: String,
  val to: String,
  val hops: List<TraceHopOut>,
  val nodePath: List<String>,
  val cost: CostOut? = null,
  /** The cost as the trace text prints it. */
  val costText: String? = null,
  /** Call paths within the depth limit. */
  val paths: Int? = null,
  /** Paths of the shown path's cost: its length for a call leg, its whole cost for a value leg. */
  val equalCostPaths: Long? = null,
  /** A count stopped at a limit, so it is a lower bound. */
  val countsIncomplete: Boolean = false,
  /** The leg's start, the cells it enters and objects it builds, and its goal. */
  val skeleton: List<String> = emptyList(),
)

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

/** `altitude-members.json`. Short keys: the file holds one row per member and member edge. */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class MembersExport(
  @EncodeDefault val schema: String = "altitude-members",
  @EncodeDefault val schemaVersion: Int = EXPORT_SCHEMA_VERSION,
  val target: String,
  val classes: List<NestedClassOut>,
  val members: List<MemberOut>,
  val edges: List<MemberEdgeOut>,
  val counts: Map<String, Int>,
)

@Serializable
data class NestedClassOut(
  val id: String,
  /** Index into `nodes` of `altitude.json`. */
  val n: Int,
  val name: String,
  val f: Int? = null,
  val l: List<Int> = emptyList(),
  /** The nested class it is declared in, as an index into `classes`. */
  val c: Int? = null,
)

@Serializable
data class MemberOut(
  val id: String,
  val n: Int,
  val k: String,
  val name: String,
  val sig: String,
  val f: Int? = null,
  /** First and last line. */
  val l: List<Int> = emptyList(),
  /** Lines the member owns: those of its span that no smaller member holds. */
  val s: Int = 0,
  val v: String? = null,
  val fl: List<String> = emptyList(),
  /** Indices into `cells` of `altitude.json`. */
  val cell: List<Int> = emptyList(),
  /** The member a local cell lives in, as an index into `members`. */
  val p: Int? = null,
  /** The nested class the member is declared in, as an index into `classes`. */
  val c: Int? = null,
  val lam: Int = 0,
  val np: String? = null,
)

/** `altitude-branches.json`: the branch trees of the precomputed roots. */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BranchesExport(
  @EncodeDefault val schema: String = "altitude-branches",
  @EncodeDefault val schemaVersion: Int = EXPORT_SCHEMA_VERSION,
  val target: String,
  /** Location ids; `loc` fields index into it. */
  val locs: List<String>,
  /** Hop records, each once, as `traces` writes them; segments index into it. */
  val hops: List<TraceHopOut>,
  val trees: List<BranchTreeOut>,
  val counts: Map<String, Int>,
)

@Serializable
data class BranchTreeOut(
  val root: BranchRootOut,
  val options: BranchOptionsOut,
  /** A search stopped at its cap, so the tree may lack terminals. */
  val truncated: Boolean = false,
  val points: List<BranchPointOut>,
  val segments: List<BranchSegmentOut>,
  val terminals: List<BranchTerminalOut>,
  val siblings: List<BranchSiblingOut> = emptyList(),
)

@Serializable
data class BranchRootOut(
  val loc: Int,
  /** Index into the members file's `members`. */
  val member: Int? = null,
  /** Index into `nodes` of `altitude.json`. */
  val node: Int? = null,
  /** `forward` or `backward`. */
  val dir: String,
  /** `cell`, `boundary`, `traceEnd` or `value`. */
  val kind: String,
  /** The cell, boundary or trace the root stands for, as an index into its list; a trace's name in [label]. */
  val ref: Int? = null,
  val label: String,
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class BranchOptionsOut(
  /** Terminal kinds a path may not pass through. */
  val stops: List<String>,
  /** Paths leave a function through the call they entered it by, as `trace --value` requires. */
  @EncodeDefault val matched: Boolean = true,
  /** Only clean terminals were kept. */
  val clean: Boolean = false,
)

@Serializable
data class BranchPointOut(
  val member: Int? = null,
  val node: Int? = null,
  val loc: Int,
  /** `root`, `branch`, `merge`, `join`, `split` or `terminal`. */
  val kind: String,
)

@Serializable
data class BranchSegmentOut(
  /** Indices into `points`, upstream first. */
  val a: Int,
  val b: Int,
  /** Indices into the file's `hops`, in data-flow order; absent when the file dropped hop detail. */
  val hops: List<Int>? = null,
  val hopCount: Int,
  /** Indices into the members file's `members`, in path order. */
  val members: List<Int> = emptyList(),
  val cost: CostOut,
  /** `anyInstance`, `anyContainer`, `fieldMismatch` and `staged`, for the hops that have them. */
  val approx: List<String> = emptyList(),
)

@Serializable
data class BranchTerminalOut(
  val point: Int,
  /** `boundary`, `cellWrite`, `cellRead`, `ui`, `entry` or `sink`. */
  val kind: String,
  /** Index into `boundaries`, `cells` or `entrypoints` of `altitude.json`, or for `ui` and `sink` the members file's `members`. */
  val ref: Int,
  val cost: CostOut,
  val equalCostPaths: Long,
  /** No any-instance or any-container read and no hop outside production code. */
  val clean: Boolean,
  /** Indices into `segments` from the root's end to the terminal's, in data-flow order. */
  val segments: List<Int>,
)

@Serializable
data class BranchSiblingOut(
  val at: Int,
  /** `join`: other values built into the object at [at]. `split`: other properties read from it. */
  val kind: String,
  val values: List<BranchSiblingValueOut>,
)

@Serializable
data class BranchSiblingValueOut(val loc: Int, val member: Int? = null, val name: String? = null)

@Serializable
data class MemberEdgeOut(
  val a: Int,
  val b: Int,
  val k: String,
  val c: Int,
  val s: List<String>,
  val d: Map<String, Int> = emptyMap(),
  /** Index into `edges` of `altitude.json` of the node edge this one is evidence for; absent inside one node. */
  val e: Int? = null,
)
