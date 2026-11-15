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
2. **Conflation.** At each hop, the bits needed to choose among the values that meet at its target (`fan-in N`), or among the containers a port may hold (`container, 1 of N`).
3. **Derived hops.** `memberOf`, `partOf`, and the step from an element to its container.

A path that enters a function through an argument or receiver leaves it through the same call's result, for the innermost six calls. A read of a property, a cell or another declaration's container forgets those calls, since the value may have been stored under any of them. A path that steps into a container's contents may not step back up to that container, and leaves the contents through the same copy of the call it entered at.

Copies (`docs/facts.md`) keep one caller's values apart from another's in small wrappers and state-holder classes. These shortcuts remain, and a path through them can rank above the real route:

- **Field-based heap.** Outside the copied classes, a property is one location for all instances.
- **No type filter.** An object reaches a location whatever the declared types.
- **Element slots**, as above.
- **A copied class's original body.** Calls dispatched on the class still run the original methods, which see every copy's value of a property that code outside the class reads.

`--via <value>,<value>` pins the route through named values and traces each leg by itself. `cell(Owner.name)` names what a cell holds.

## Model files

| File | Covers |
| --- | --- |
| `kotlin-stdlib.yaml` | Scope functions, collection and sequence operators, builders, `Pair`, `lazy`, `Result`, `use`, `synchronized` |
| `kotlinx-coroutines.yaml` | Coroutine builders, `Flow` operators, `StateFlow`, `SharedFlow`, `Channel`, `Mutex` |
| `compose.yaml` | `remember`, `mutableStateOf`, effects, `collectAsState`, `@Composable` content parameters |
| `magellanx.yaml` | Fields attached to a lifecycle and their delegates, `composable` content |

To add a model: find the callee in `unmodelledLambdaCall.jsonl`, write the entry, and add a fixture under `extractor/src/test/resources/fixture/models/` with a test in `ModelsTest`.
