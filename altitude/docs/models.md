# Altitude library models

A model states what a function outside the sources does with the values it is given. The solver has no body to read for `map`, `launch` or `MutableStateFlow.update`, so without a model a value that enters one is lost and a lambda passed to one is only assumed to run. Models are YAML files under `models/`, bundled into the command. `facts --models <dir>` and `solve --models <dir>` replace the built-in set.

## An entry

```yaml
entries:
  - id: map
    match: [fun:kotlin/collections/map, fun:kotlin/sequences/map]
    flows:
      - receiver.element -> arg[transform].param[0]
      - arg[transform].return -> result.element
    invokes:
      - lambda: "arg[transform]"
        role: transform, run in place for each element
```

| Key | Meaning |
| --- | --- |
| `id` | Names the entry. A derived edge carries `ruleId` `<file>#<id>`. |
| `match` | One callee or a list. See "Matching". |
| `receiver` | Applies the entry only when the extension receiver's class is this one. |
| `flows` | `from -> to` pairs of ports. Each becomes `summary` flow edges at the call. |
| `triggers` | `from -> to` pairs of element ports where a write to `from` makes `to` emit. It carries no value, only the fact that one stream drives another. |
| `invokes` | The lambdas the callee runs. Each becomes an `invoke` call edge from the call site's declaration. |
| `cell` | The call's result is a cell, with this mechanism name. See "Cells". |
| `writes`, `reads` | The call writes to, or reads from, the cell a port names, as `{port, op}`. |

An unknown key fails the load, at the entry and inside `invokes`.

An `invokes` item has `lambda` (a port), `role` (free text, printed in the trace), and two optional keys. `whenAnnotated: <annotation>` applies the item only when the library parameter's type carries that annotation, which is how `@Composable` content is told apart from an event callback. `perValueOf: <element port>` or a list of them records, besides the call edge, that the lambda runs once per value written to that slot; this is what turns `collect { }` into the reader end of a cell. The key is not named `on`, because YAML reads a bare `on` as `true`.

## Matching

A model matches the callee symbol the Analysis API resolved, never a name in the source. An import alias, a shadowing local function or a same-named function in another package cannot match by accident.

- A `match` that equals the callee's whole ID, parameters included, wins.
- Otherwise the ID is compared without its receiver and parameter list, so one line covers every overload: `fun:kotlin/collections/map`. A property keeps its accessor: `prop:kotlinx/coroutines/flow/StateFlow.value#<get>`.
- Otherwise the longest `match` that ends in `**` and is a prefix of the ID wins.
- Entries are tried in file order, files in name order. An entry with `receiver:` goes before an unconstrained entry for the same callee. A property ID has no receiver, so `receiver:` never applies to one.

## Ports

A port names a location at the call, or a slot reached from one.

| Port | Names | Why it exists |
| --- | --- | --- |
| `receiver` | The dispatch or extension receiver | Most library functions are extensions; the receiver is their main input. |
| `arg[i]`, `arg[name]` | An argument by position or parameter name | Names survive reordering and named arguments; positions cover Java callees. |
| `result` | The value of the call | The output. |
| `<port>.param[i]` | Parameter `i` of each lambda that reaches the port | A library passes values into a lambda, and nothing else connects `it` to the collection. |
| `<port>.receiver` | The receiver of each such lambda | `apply`, `with`, `launch` and builders hand the lambda a `this`. |
| `<port>.return` | What each such lambda returns | `map`, `let` and `async` use the lambda's value. |
| `<port>.element` | The contents of each object that reaches the port | See "Elements". |

`param`, `receiver` and `return` resolve through the solver's function values, so a lambda stored in a variable or passed as `::handle` works the same as one written in place. `.element` resolves through the objects that reach the port.

## Elements

Every container has one **element slot**, `<root>#<elem>`, where `<root>` is the expression that created the object: a `listOf(…)` call, a `MutableStateFlow(…)` call, a parameter the sources never assign. `receiver.element -> result` on `first` therefore means "anything put into any list that may reach this receiver comes out here".

This is the cheapest abstraction that keeps a value connected to the collection it went into. What it gives up:

- **No positions or keys.** A `Map` has one slot for keys and values alike, so does a `Pair` and a `Triple`. `map.get(k)` returns anything stored under any key.
- **One level of nesting.** A list of lists has a slot for the inner lists, but an inner list found only as an element has no slot of its own. Deeper nesting would create slots without bound.
- **`groupBy`, `chunked` and the like** make the result's element the receiver's element, losing the grouping.
- **A stream's slot is every value it ever carries.** `filter` and `distinctUntilChanged` pass everything.

The solver records which objects reach a port as `contentOf` edges, from the port to each slot. They show in a value trace so a reader sees which container a hop went through.

## Cells

A cell is an object written at one place and read at another with no call between the two: `MutableStateFlow`, `MutableSharedFlow`, `Channel`, a Compose `MutableState`, and the results of `stateIn` and `collectAsState`. An entry with `cell:` makes each of its calls a cell. `writes` and `reads` entries name the operations, and the solver derives:

- `cell`: `id` (the creating call), `sym` (the property or local that holds it, when one is found), `mechanism`.
- `cellWrite` and `cellRead`: `cell`, `at`, `op`, `decl`.
- A `cell` **call edge** from each declaration that writes, to each lambda the model runs per value (`perValueOf`). `through` counts the operators between the cell and the collector, following `triggers` and element-to-element `flows`. A write with `op: initial` makes no call edge.

The call edge is what joins `syncRequests.tryEmit(Unit)` to the `collect { }` three functions away. The value takes the ordinary route: `arg[value] -> receiver.element` on the write, `receiver.element -> result` on the read.

## What the solver does with a model

- A lambda passed to a callee that lists it in `invokes` gets an `invoke` call edge with `ruleId`, `role` and `invoker`.
- A lambda passed to a library callee that does not list it keeps the `assumedInvoke` edge and a row in `unmodelledLambdaCall`. That table is the worklist for new models.
- A library **property** read or written through a receiver is a `get` or `set` call, so `state.value` can be modelled. An unmodelled library property carries nothing between its writes and reads.

## What a value trace over-approximates

`trace --value` follows every flow edge, extracted and derived, including three kinds the solver itself never propagates along: `memberOf` (an object to anything read from it), `contentOf` (a container to its slot) and `partOf` (a constructor or `copy` argument to the object built from it). They make the trace a taint trace: the value, or anything it was built from or built into. A path means "data may flow", and the reader checks each hop.

The trace prints the best path. It ranks paths by these counts, most important first, and breaks ties by length:

1. **Any-instance reads.** A read of a class property with no copy to say whose, or of a container's contents at another call than the one that stepped into it.
2. **Hops outside production code.** A hop into a test source set, a declaration under an annotation named `…Preview…`, or a class with the word `Fake` in its name.
3. **Conflation.** At each hop, the bits needed to choose among the values that meet at its target (`fan-in N`), or among the containers a port may hold (`container, 1 of N`).
4. **Derived hops.** `memberOf`, `partOf`, and the step from an element to its container.

Among paths of equal cost, the trace prints the one its search reaches first. The search visits edges in sorted order, so the output is the same on every run. The search stops after `searchBudget` steps (2,000,000) and then says it is incomplete. It prints any path it found by then and says that a cheaper one may exist.

### Matching calls and returns

The trace keeps a list of the calls the path is inside of, innermost last, at most six. An empty list means "unknown". A return edge follows these rules:

- If the list is empty, the path may take any return edge.
- If the innermost call is the call that the edge returns to, the path takes it and drops that call.
- Otherwise the trace rejects the edge.

The rule never drops a path that can happen, because the trace keeps the list only while the list provably describes the run of the function that the value is in. A run is one execution of a function, a lambda or an initializer. The list survives these edges and no others:

- **An edge inside one run.** Both ends belong to the same function or lambda, in the same copy. A lambda written as an argument whose function value goes nowhere else counts as part of the run that wrote it: only that call can run it, and it captures that run's variables.
- **Entry into a call.** The edge passes an argument or a receiver. The trace adds the call. When the same expression is the receiver of several calls, as an implicit `this` is, the trace adds "one of these calls", and a return to any of them matches. When the expression belongs to another run than the call does, the trace first empties the list.
- **The matching return**, as above.
- **A library summary or an override.** The summary stays at one call site, and an override runs under the calls of the function it overrides.
- **A container's contents**, when the path leaves them at the same call that stepped into them, or steps back to the container at the same call that filled them.

Every other edge between two runs empties the list: a captured variable, a property, a cell, a container's contents read at another call, a DI link, a bound reference's receiver. A value stored in one of these can be read by a run under any calls. After the list is empty, every return is allowed, so the trace loses precision there and never a path. Six calls is not a soundness limit either: the trace drops the outermost call, and a return with an empty list is always allowed.

A path that steps into a container's contents may not step back up to that container. It leaves the contents through the copy of the call that it entered at, unless the target exists only outside that copy, as a lambda that the caller passed to a copied wrapper does.

### What stays approximate

Copies (`docs/facts.md`) keep one caller's values apart from another's in small wrappers and state-holder classes. These shortcuts remain, and a path through them can rank above the real route:

- **Field-based heap.** Outside the copied classes, a property is one location for all instances.
- **No type filter.** An object reaches a location whatever the declared types.
- **No field in `partOf` and `memberOf`.** An object carries everything built into it, so a value that entered an object as one constructor argument leaves it through any property. Pin the route with `--via Owner.property` when that matters.
- **Element slots**, as above.
- **Access to a copied class from outside.** Code outside a copied class that calls a member, reads or writes a property, or takes a reference to a member may hold any copy. Each such flow goes to every copy and to the original, so a value that one construction passed can leave through a member call made on another construction's object. Nothing is lost: the original body's properties receive what outside code writes, and each copy's properties receive what its own construction passed.
- **Another instance inside a copied class.** A member of a copied class that touches another instance of the same class (`other.field`) stays in its own copy. This is the one known place where a copy can drop a real flow. The facts do not record the receiver of a property write, so the copier cannot detect it.
- **Nested wrappers.** A wrapper that is called from a wrapper is copied once per outer call for two levels. Deeper wrappers share one copy, so their callers' values meet.

`--via <value>,<value>` pins the route through named values and traces each leg by itself. `cell(Owner.name)` names what a cell holds.

## Model files

| File | Covers |
| --- | --- |
| `kotlin-stdlib.yaml` | Scope functions, collection and sequence operators, builders, `Pair`, `lazy`, `Result`, `use`, `synchronized` |
| `kotlinx-coroutines.yaml` | Coroutine builders, `Flow` operators, `StateFlow`, `SharedFlow`, `Channel`, `Mutex` |
| `compose.yaml` | `remember`, `mutableStateOf`, effects, `collectAsState`, `@Composable` content parameters |
| `magellanx.yaml` | Fields attached to a lifecycle and their delegates, `composable` content |

To add a model: find the callee in `unmodelledLambdaCall.jsonl`, write the entry, and add a fixture under `extractor/src/test/resources/fixture/models/` with a test in `ModelsTest`.
