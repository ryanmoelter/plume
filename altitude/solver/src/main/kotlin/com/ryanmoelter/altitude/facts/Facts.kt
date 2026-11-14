package com.ryanmoelter.altitude.facts

import kotlinx.serialization.Serializable

/** The relations are documented in `altitude/docs/facts.md`. */
const val SCHEMA_VERSION = 2

/** A target of a call that did not resolve. */
const val UNRESOLVED_TARGET = "UNRESOLVED"

@Serializable
data class ModuleFact(
  val name: String,
  val platform: String,
  val fragments: List<String> = emptyList(),
  val dependsOn: List<String> = emptyList(),
)

@Serializable
data class FileFact(
  val path: String,
  val module: String,
  val generated: Boolean,
  val sourceSet: String? = null,
  val syntaxErrors: Int = 0,
)

@Serializable
data class DeclFact(
  val sym: String,
  val kind: String,
  val name: String,
  val owner: String? = null,
  val file: String? = null,
  val span: String? = null,
  val type: String? = null,
  val modifiers: List<String> = emptyList(),
  val fnTyped: Boolean = false,
  /** The position of a parameter in its owner's parameter list. */
  val index: Int? = null,
)

@Serializable
data class SupertypeFact(
  val cls: String,
  val sup: String,
  val viaDelegation: Boolean = false,
  /** The location holding the delegate of `: sup by delegate`. */
  val delegate: String? = null,
  /** The class of the delegate expression's static type. */
  val delegateType: String? = null,
)

@Serializable data class OverrideFact(val sym: String, val overridden: String)

@Serializable data class ActualForFact(val actual: String, val expect: String)

@Serializable
data class AnnotationFact(val sym: String, val annFq: String, val args: List<String> = emptyList())

@Serializable
data class NodeFact(
  val id: String,
  val kind: String,
  val enclosingDecl: String,
  val type: String? = null,
  val fnTyped: Boolean = false,
  /** What a reference refers to, the lambda a `lambdaExpr` declares, or the call of a result. */
  val target: String? = null,
  /** A `callableRef` whose receiver is bound (`x::foo`); the first parameter is not the receiver. */
  val bound: Boolean = false,
)

@Serializable
data class CallFact(
  val id: String,
  val callerDecl: String,
  val target: String,
  val dispatch: String,
  val targetInSource: Boolean = false,
  /** Locations whose value is the dispatch receiver; for `invokeFnValue` the function value. */
  val receiver: List<String> = emptyList(),
  val extReceiver: List<String> = emptyList(),
  /** `dispatch` and/or `extension` when that receiver is an implicit `this`. */
  val implicit: List<String> = emptyList(),
  /** The class of the dispatch receiver's static type. */
  val receiverType: String? = null,
  val result: String? = null,
)

@Serializable
data class ArgFact(
  val call: String,
  val param: String,
  val index: Int,
  val node: String,
  /** `positional`, `named`, `vararg`, `spread`, `trailingLambda`, `receiver` or `operand`. */
  val form: String,
  /** Annotations on the parameter's type, such as `androidx/compose/runtime/Composable`. */
  val typeAnnotations: List<String> = emptyList(),
)

@Serializable
data class FlowFact(
  val from: String,
  val to: String,
  val kind: String,
  val at: String,
  /** The model entry behind a `summary` or `contentOf` edge, as `<file>#<entry>`. */
  val ruleId: String? = null,
)

/** A call of a function outside the sources that takes a function value. */
@Serializable data class LambdaCallFact(val call: String, val callee: String)

@Serializable
data class UnresolvedFact(
  val at: String,
  val kind: String,
  val text: String,
  val diagnostic: String? = null,
)

@Serializable
data class FnValueFact(
  val call: String,
  /** A lambda declaration or a referenced function, constructor or property. */
  val value: String,
  /** Flow edges from the node that creates the value to the invoked location. */
  val witness: List<FlowFact> = emptyList(),
)

@Serializable
data class CallEdgeFact(
  val call: String,
  val caller: String,
  val callee: String,
  /** `static`, `cha`, `fnValue`, `invoke`, `assumedInvoke`, `cell`, `actual`, `delegateAccessor` or `init`. */
  val via: String,
  /** The model entry behind an `invoke` edge. */
  val ruleId: String? = null,
  /** What an `invoke` edge's lambda is to its invoker: `block`, `content`, `event` and the like. */
  val role: String? = null,
  /** The library callable that runs the lambda of an `invoke` edge. */
  val invoker: String? = null,
  /** The object a `cell` edge's caller writes; a `cell` row when it is a state cell. */
  val cell: String? = null,
  /** A `cell` edge's write and read operations, as `tryEmit → collect`. */
  val op: String? = null,
  /** Derived streams between the written object and the one the callee reads. */
  val through: Int = 0,
)

/** A state holder or stream created by a modelled call, named by the call's result node. */
@Serializable
data class CellFact(
  val id: String,
  /** The property or local that holds the cell. */
  val sym: String? = null,
  val mechanism: String,
)

/** [node] is the call that writes or reads the element of [cell]. */
@Serializable data class CellAccessFact(val cell: String, val node: String, val op: String)

@Serializable data class FanOutFact(val call: String, val count: Int)

@Serializable
data class MetaFact(
  val schemaVersion: Int = SCHEMA_VERSION,
  val gitSha: String? = null,
  val gitDirty: Boolean? = null,
  val manifestKotlinFiles: Int = 0,
  val loadedKotlinFiles: Int = 0,
  val filesWithSyntaxErrors: Int = 0,
  val duplicateDeclIds: Int = 0,
  val rows: Map<String, Int> = emptyMap(),
)

/** What the extractor writes. Row order carries no meaning; [FactStore] sorts on write. */
data class Facts(
  val modules: List<ModuleFact> = emptyList(),
  val files: List<FileFact> = emptyList(),
  val decls: List<DeclFact> = emptyList(),
  val supertypes: List<SupertypeFact> = emptyList(),
  val overrides: List<OverrideFact> = emptyList(),
  val actuals: List<ActualForFact> = emptyList(),
  val annotations: List<AnnotationFact> = emptyList(),
  val nodes: List<NodeFact> = emptyList(),
  val calls: List<CallFact> = emptyList(),
  val args: List<ArgFact> = emptyList(),
  val flows: List<FlowFact> = emptyList(),
  val libraryLambdaCalls: List<LambdaCallFact> = emptyList(),
  val unresolved: List<UnresolvedFact> = emptyList(),
)

/** What the solver adds. */
data class Derived(
  val flows: List<FlowFact> = emptyList(),
  val fnValues: List<FnValueFact> = emptyList(),
  val callEdges: List<CallEdgeFact> = emptyList(),
  val fanOuts: List<FanOutFact> = emptyList(),
  val unmodelledLambdaCalls: List<LambdaCallFact> = emptyList(),
  val cells: List<CellFact> = emptyList(),
  val cellWrites: List<CellAccessFact> = emptyList(),
  val cellReads: List<CellAccessFact> = emptyList(),
)
