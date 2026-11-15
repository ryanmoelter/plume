# The export

`extractor export --facts <dir> --out <dir> --target <name> [--golden golden/<target>] [--split]` reads a solved facts directory and writes `altitude.json`. Visualization pages read this one file. Every number in it derives from the facts and the rule relations, never from a class or package name.

The file is deterministic. Keys of maps are sorted, lists are sorted by id, and no absolute path appears. Two runs over the same commit give the same bytes, also from two checkouts at different paths. A field at its default value is left out: an empty list, `false`, `0` or `null`.

If the encoded file would exceed 4,000,000 characters, or with `--split`, the export writes two files:

- `altitude.json` keeps every top-level field. Its nodes keep only the summary fields: `id`, `kind`, `name`, `container`, `feature`, `file`, `line`, `generated`, `staged`, `size`, `layer`, `layerWhy`, `infrastructure` and `roles`. `bundles` loses `argGroups`. `meta.detailFile` names the second file.
- `altitude-nodes.json` holds `schemaVersion`, `nodes` (a map from node id to the remaining node fields) and `argGroups`.

A page merges a node's detail into its summary by id.

## Identifiers

- A **node** is the outermost named class of a declaration (`class:<pkg>/<Name>`, the facts' class symbol), or `top:<path>` for the top-level declarations of one file. Anonymous objects and nested classes fold into their outermost named class.
- A **site** is `<index into files>:<line>`. `files` lists every source path, sorted.
- A **cell** is referred to by its index into `cells`, an **entry point** by its index into `entrypoints`, and an **edge** by its index into `edges`.

## Top level

| Field | What it holds |
|---|---|
| `schema`, `schemaVersion` | `"altitude-export"` and `1`. |
| `meta` | `target`, `gitSha`, `gitDirty`, `factsSchemaVersion`, the constants the derivations use (`params`), the layer names (`layers`) and row `counts`. |
| `files` | Every source path, relative to the target root. |
| `containers` | The containment tree. |
| `features` | The horizontal slices. |
| `nodes` | Classes and files, with placement, reach, fan-in and roles. |
| `edges` | Node-to-node relations, aggregated. |
| `cells` | State cells with their writers and readers. |
| `entrypoints`, `boundaries`, `bindings`, `navigations` | The rule rows, with each row's node. |
| `bundles` | Wraps and argument groups, for drawing strands and ribbons. |
| `patterns` | A pattern vector for the target and for each feature, plus the loops. |
| `traces` | The golden traces, as hops over nodes and edges. |

## Containers

There is one containment relation. Each container has an `id`, a `kind`, a `parent`, a `name`, a `qualified` name, a `depth` and a `size` (`loc`, `decls`, `nodes`, summed over the nodes inside it).

| Kind | Id | Parent |
|---|---|---|
| `module` | `module:<gradle path>` | none |
| `sourceSet` | `sourceSet:<module>/<source set>` | its module |
| `package` | `package:<module>/<source set>/<qualified package>` | the nearest enclosing package, else the source set |
| `file` | `file:<path>` | its package |

A node's `container` is its file. A module is only one kind of container; a page can draw any level.

## Features

A feature is a horizontal slice of one module. The module's **root package** is the longest package prefix shared by its hand-written files. A feature is the root plus one more package segment, and a file directly in the root belongs to the root's own feature. The id is `feature:<module>/<package>`. A feature lists its package containers, its size and how many entry points sit in it.

## Nodes

### Placement

`placement` is the raw evidence behind the layer.

- `down`: per boundary kind, the call hops from the node to a call of that kind. The calling declaration is 1. `min` is over all the node's declarations; `median` is over its named callables that reach the boundary; `reaching` counts them.
- `up`: per entry point kind, the call hops from an entry point's callables to the node. The callable itself is 0.
- `boundaryCalls`: boundary calls the node makes, by kind.
- `entryKinds`: kinds of the entry points the node hosts.
- `cells`: cells the node owns, writes and reads.
- `ui`: composable functions, all functions, cell reads in composable code and event lambdas.
- `dataType`: the node holds data and no behavior. It is a data, enum, value, sealed or annotation class, or it declares properties and no functions. A node that owns a cell is never a data type.

Distances run over the solved call graph with two corrections:

- A `cha` call with more than `params.megamorphic` (8) candidates is left out. Such a call is generated dispatch, and it would put every candidate one hop from its caller.
- A callback lambda is entered only after its gate. The gate is the lambda's nearest enclosing callable, or its class and constructors. Another entry point's callable is entered only by a static call. Without these, a shared component's caller reaches every lambda anyone passed to it, and framework dispatch reaches every screen.

### Layer

`layer` is an index into `meta.layers`: 0 `external`, 1 `data`, 2 `presentation`, 3 `ui`. The first rule that matches sets it, and `layerWhy` names that rule.

| `layerWhy` | Rule | Layer |
|---|---|---|
| `boundaryTarget` | The node holds the library end of a boundary: a boundary target in the sources, or an operation class. | 0 |
| `composable` | It hosts no entry point, and at least half its functions are composable. | 3 |
| `entryHost` | It hosts an entry point. | 2 |
| `boundaryCaller` | It makes a boundary call that is not telemetry (`posthog`, `sentry`). | 1 |
| `closerToBoundary:d<=u` | It reaches a data boundary in `d` hops and is reached from an entry point in `u`, and `d <= u`. | 1 |
| `closerToEntry:d>u` | The same, with `d > u`. | 2 |
| `reachesBoundary` | It reaches a data boundary and no entry point reaches it. | 1 |
| `inheritsFromCallers` | A data type, or a node no rule above placed. It takes the lowest layer among its direct callers, repeated until nothing changes. A caller in layer 0 counts only when no other caller is placed, because an external adapter builds the models it returns. | caller's |
| `unusedDataType`, `unplaced` | Nothing places it. `layer` is absent. | none |

Direct callers are joined by `static`, `cha`, `actual`, `init` or `delegateAccessor` call edges, not by callbacks.

### Reach, fan-in and infrastructure

- `reach.entries`: the entry points whose gated reach includes one of the node's declarations. `reach.byContainer` lists their distinct `feature` and `module`.
- `fanIn`: the nodes that depend on this one, as `nodes` (a count), `features` (other than its own) and `layers`. A node depends on another when it calls it directly, reads one of its cells or is injected with it. Value edges stay out, because an argument flows against the dependency.
- `infrastructure.score`: the share of all features that use the node or reach it from their entry points. `flag` is true when the node is used by at least `params.infraFeatures` (3) other features, reached from 3 features, or used from 3 layers. `why` lists the conditions that held.
- `misplaced`: the node's feature has entry points of its own, but every entry point that reaches the node sits in one other feature. `container` is the node's feature and `reachedOnlyFrom` the other one.

### Roles

Each role carries an `evidence` object. A node may have several roles. No role reads a class or package name.

| Role | Holds when | Evidence |
|---|---|---|
| `entryPoint` | It hosts an entry point. | `kinds` |
| `screenHost` | An entry host with composable functions. | `composableFuns`, `propertyCells` |
| `stateHolder` | It owns a cell held in a property. | `propertyCells`, `mechanisms`, `readByNodes` |
| `uiState` | It owns local cells and has composable functions. | `localCells` |
| `stateWriter` | It writes cells another node owns. Writes into a cell of a staged node (a test, preview or fake class) do not count. | `cellsOfOtherNodes`, `owners` |
| `uiReader` | Its composable code reads cells. | `uiReads` |
| `uiComponent` | The `composable` layer rule holds. | `composableFuns`, `funs` |
| `boundaryAdapter` | It makes a boundary call. | `calls` |
| `externalAdapter` | The `boundaryTarget` rule holds. | `generated` |
| `mediator` | Not an entry host, no composables, not data. It reaches a data boundary and has presentation-layer direct callers. | `presentationCallers`, `propertyCells`, `boundaryHops`, `callsBoundaryDirectly` |
| `diGraph` | It is the graph or the provider of DI bindings. | `graphBindings`, `providedBindings` |
| `navigator` | It makes navigation calls. | `navigations` |
| `pureData` | `placement.dataType` holds. | `modifiers` |

A node is `staged` when only tests, previews or fakes run it: it sits in a test source set, under a preview annotation, or is a fake.

## Edges

An edge aggregates every fact of one `kind` from one node to another. Self edges are dropped. `count` is the number of distinct facts, `sites` lists up to `params.evidenceSites` (3) of their positions in source order, and `detail` counts the facts by subkind.

| Kind | From → to | `detail` keys |
|---|---|---|
| `call` | caller → callee, over every solved call edge except `di` and `cell` | the call edge's `via` |
| `di` | injection site → provider | `accessor` (a graph accessor call) or `injection` (an injected value) |
| `value` | where a value flows from → where it flows to, over value flows other than `memberOf`, `partOf`, `contentOf` and `di` | the flow's `kind` |
| `cellWrite` | writing node → cell owner | the write op |
| `cellRead` | cell owner → reading node | the read op |
| `navigation` | navigating node → destination | the navigator op |

`crossesLayer` and `crossesFeature` compare the two ends.

## Cells

A cell is a state container the solver found. `holder` is the declaration that holds it, `owner` its node and `scope` is `property` or `local`. `mechanism` names the library type. `elementType` is the node of the cell's first type argument, when that type is in the sources. `writers` and `readers` group accesses by node, op and `context`: `ui` in composable code or a content lambda, `uiEvent` in an event lambda a composable passes, else `code`. The initial value is not a write.

## Bundles

- `wraps`: from each `partOf` flow, the node of the inner value's type and the node of the outer object's type. A chain of wraps forms a strand.
- `argGroups`: a call between two nodes with at least two non-receiver arguments. `params` names the parameters in order, and `types` gives each argument's type node. Arguments of one call form a ribbon.

## Patterns

`patterns.target` and each entry in `patterns.features` hold `counts`, a `label` and `because`, the counts the label rests on.

| Count | Meaning |
|---|---|
| `nodes`, `entryHosts`, `hostsWithUi`, `hostsOwningState` | Nodes, entry hosts, entry hosts with composables, entry hosts that own a property cell. |
| `holders.perScreen`, `holders.shared`, `holders.unreached` | State holders that are not entry hosts, by how many screen hosts reach them: one, several, none. |
| `mediators` | Nodes with the `mediator` role. |
| `cells.<scope>`, `cells.property.<owner role>` | Cells, by scope and by their owner's role. |
| `writes.<context>`, `writes.<context>.to.<owner role>`, `writes.crossNode` | Cell writes, by context and owner; writes into another node's cell. |
| `reads.ui.of.<owner role>` | Cell reads in composable code, by owner. |
| `eventCalls.sameNode`, `eventCalls.otherNode` | Calls from event lambdas, inside or outside the lambda's node. |
| `singleStateHosts` | Entry hosts whose only non-Compose property cell has an element type in the sources. |
| `reducers` | Functions shaped `(S, E) -> S`, where E is a sealed type in the sources. |
| `loops`, `loops.<owner role>` | Loops, by the role of the written cell's owner. |
| `loopReaders.deepest.<owner role>` | Nodes with a loop, by the deepest owner role among their loops. |

The owner roles, deepest first, are `repository` (a mediator that makes a non-telemetry boundary call), `mediator`, `host` (an entry point), `ui` and `other`.

A **loop** is a unidirectional data loop. Composable code in the reader node reads a cell. One of the reader's event lambdas reaches, within `params.loopHops` (40) call hops, a write to that cell, or to a cell whose element flows into it. Staged writers and staged owners do not count. `patterns.loops` lists each one: the cell read, the cell written, its owner and owner role, the reader, the writer and the hops.

The label joins these parts with "with a":

- **screen-hosted MVP**: some entry hosts own state and have composables, event lambdas call into their own node, and fewer state holders serve one screen each than hosts own state.
- **MVVM**: otherwise, if per-screen holders are at least as many as hosts owning state.
- **MVI**: there are reducers, and at least half the hosts owning state have a single typed state.
- **`<role>-level unidirectional loop`**: the owner role that is deepest for the most loop readers. A tie goes to the deeper role.
- **stateless request handling**: none of the above, no property cells and some entry hosts.

## Traces

Each golden query under `--golden` runs again over the facts, through the same search `extractor trace` uses. A trace has `name`, `query`, `comment`, `kind` (`call` or `value`) and `legs`. A leg has its endpoints, its `hops` and `nodePath`, the nodes it passes through with consecutive repeats collapsed.

A hop has `from`, `to`, `kind` (the call edge's `via` or the flow's kind), `site` (`path:line`, as the trace text prints it), the model `rule`, `fromNode`, `toNode` and `edge`, the index of the aggregated edge it belongs to. `wrapDepth` is how many objects deep the traced value is after the hop: `partOf` and `heldBy` add one, and `memberOf` or `contentOf` into an element take one away.

`matchesGolden` is true when every hop renders the same as the hop line of the golden trace text.
