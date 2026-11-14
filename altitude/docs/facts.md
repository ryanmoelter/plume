# Altitude facts

`facts` writes one JSON Lines file per relation into the output directory, plus `meta.json`. `solve` adds the derived relations to the same directory. Every file holds distinct lines sorted by their text, with no timestamp, host name or absolute path, so two runs on the same checkout write the same bytes.

```
extractor facts --manifest <manifest.json> --out <dir>     # extracts, then solves
extractor solve --facts <dir>                              # re-derives from the files
extractor trace --facts <dir> --from <selector> --to <selector> [--max-depth N] [--alternates N]
extractor trace --facts <dir> --from <selector> --forward [--max-depth N] [--limit N]
extractor show  --facts <dir> --file <relpath>
```

A field that holds its default (`false`, `null`, an empty list) is left out of the line.

## Identifiers

A declaration with a qualified name gets the same ID from every file that refers to it.

| Kind | Form |
| --- | --- |
| Class, interface, object | `class:<package>/<Outer.Inner>` |
| Function | `fun:<package>/<Owner.name>[@<receiver type>](<parameter types>)` |
| Constructor | `ctor:<package>/<Class>(<parameter types>)` |
| Property | `prop:<package>/<Owner.name>[@<receiver type>]` |
| Enum entry | `enumEntry:<package>/<Enum.ENTRY>` |
| Parameter | `<owner ID>#<name>`; a lambda's implicit parameter is `<lambda ID>#it` |
| Local declaration, lambda, node, call | `<relpath>:<line>:<col>-<line>:<col>:<kind>` |

- A type in an ID is its class ID with type arguments (`kotlin/collections/List<app/Expense>`), `?` when nullable, and `...` after a vararg parameter. A type parameter is its name. Type aliases are expanded. Type arguments stay because two overloads may differ only in them.
- An `expect` declaration ends in `|expect`. Its `actual` has the plain ID, and `actualFor` links the two.
- A private top-level declaration ends in `@<File.kt>`, because two files of one package may each declare one.
- A path is relative to the repository root. A generated file is `gen/<gradle project>/<path under the build directory>`, with `_root` for the root project.

Value locations that are not declarations hang off an ID:

| Suffix | Meaning |
| --- | --- |
| `#<this>` | Dispatch receiver of a function, constructor or accessor |
| `#<recv>` | Extension receiver of a function, or receiver of a lambda with receiver |
| `#<ret>` | Returned value |
| `#<get>`, `#<set>` | A property's accessors, which are declarations when the source writes them |
| `#<delegate>` | A property's `by` delegate object |
| `<class ID>#<delegate:<interface>>` | The object a class delegates an interface to |

## Extracted relations

| File | Fields |
| --- | --- |
| `module` | `name`, `platform`, `fragments`, `dependsOn` |
| `file` | `path`, `module`, `generated`, `sourceSet`, `syntaxErrors` |
| `decl` | `sym`, `kind`, `name`, `owner`, `file`, `span`, `type`, `modifiers`, `fnTyped`, `index` |
| `supertype` | `cls`, `sup`, `viaDelegation`, `delegate`, `delegateType` |
| `override` | `sym`, `overridden` |
| `actualFor` | `actual`, `expect` |
| `annotation` | `sym`, `annFq`, `args` |
| `node` | `id`, `kind`, `enclosingDecl`, `type`, `fnTyped`, `target`, `bound` |
| `call` | `id`, `callerDecl`, `target`, `dispatch`, `targetInSource`, `receiver`, `extReceiver`, `implicit`, `receiverType`, `result` |
| `arg` | `call`, `param`, `index`, `node`, `form` |
| `flow` | `from`, `to`, `kind`, `at` |
| `unmodelledLambdaCall` | `call`, `callee` |
| `unresolved` | `at`, `kind`, `text`, `diagnostic` |

- **`decl.kind`** is `class`, `interface`, `object`, `enumEntry`, `fun`, `ctor`, `prop`, `getter`, `setter`, `param`, `local` or `lambda`. `modifiers` holds visibility, modality, `suspend`, `inline`, `member`, `receiver`, `default`, `vararg`, `ctorParam`, `anonymous`, `implicit` and the like. A function-typed parameter whose type carries an annotation has `typeAnnotation:<fq name>`, so `@Composable () -> Unit` stays distinguishable from an event callback. `fnTyped` marks a declaration whose type is a function type.
- **`node.kind`** is `lambdaExpr`, `callableRef`, `objectCreation`, `callResult`, `paramRef`, `propRef`, `localRef`, `literal`, `thisRef` and the like. `target` is what a reference names. `bound` marks a callable reference with a bound receiver.
- **`call.dispatch`** is `static`, `virtual`, `invokeFnValue` (a call through a function value), `delegateAccessor` (a `by` delegate's `getValue`, `setValue` or `provideDelegate`) or `init` (a secondary constructor running the class initializers). `target` is `UNRESOLVED` when the call did not resolve. `receiverType` is the static type of a virtual call's receiver. `implicit` lists the receivers the source did not write.
- **A property access is a call only when it can run code**: the property has an accessor body, a delegate, or is open or abstract. The call's kind is `get` or `set` and its target is `<prop ID>#<get>` or `#<set>`. Every other access is a `fieldRead` or `fieldWrite` flow.
- **Initializer code** belongs to the primary constructor, or to the class when it has none.
- **`arg.form`** is `positional`, `named`, `trailingLambda`, `vararg`, `spread`, `operand` or `receiver`. An `invokeFnValue` call's arguments are positional with the function type's receiver first, whether the source wrote it as `x.block()`, as `block(x)`, or left it implicit.
- **`flow.kind`** is `assign`, `init`, `arg`, `return`, `capture`, `read`, `receiver`, `fieldRead`, `fieldWrite`, `delegate`, `default`, `sam`, `iteration` or `destructure`. `at` is the source position that causes the edge.
- **`unresolved.kind`** is `call`, `name`, `type`, `callableReference`, `delegate`, `errorReceiver` (a reference through a receiver of error type), `syntax` or `exception`.

`meta.json` holds the schema version, the target's git SHA and dirty flag, the count of Kotlin files in the manifest and of files loaded, the count of files with syntax errors, the count of duplicate declaration IDs, and the row count of each extracted relation. The extractor fails when a Kotlin file of the manifest was not loaded.

## Derived relations

| File | Fields |
| --- | --- |
| `flowDerived` | As `flow`, with kinds `override`, `invokeArg`, `invokeReturn` |
| `fnValue` | `call`, `value`, `witness` |
| `callEdge` | `call`, `caller`, `callee`, `via` |
| `fanOut` | `call`, `count` |

- **`fnValue`**: the lambda, function or property `value` reaches the `invokeFnValue` call (or a call of a `fun interface` method). `witness` is the list of flow edges from the value's expression to the invoke, in order.
- **`callEdge.via`** is `static`, `cha`, `fnValue`, `assumedInvoke`, `actual` (an `expect` target dispatched to its `actual`), `delegateAccessor` or `init`.
- **`fanOut`** has one row per `invokeFnValue` call, including a count of 0.

## The model and what it leaves out

The solver is flow-insensitive, context-insensitive and field-based: a property is one location for every instance of its class. It propagates function values from `lambdaExpr` and `callableRef` nodes along flow edges to a fixpoint.

- **`cha`.** A virtual call dispatches to every override in a subclass of the receiver's static type. A class that delegates an interface with `by` dispatches to the overrides of the delegate's static type.
- **`assumedInvoke`.** A lambda or function reference passed to a function outside the sources is assumed to be invoked by it, from the call site. Nothing says when, how often, or with what arguments; `launch { }` and `map { }` look the same. `unmodelledLambdaCall` lists every such call.
- **Fan-out is an upper bound per property, not per instance.** Two objects of one class that hold different lambdas both show both lambdas.

The model leaves these out:

- **Values sent through a channel-like object.** `MutableSharedFlow.emit` and `collect`, `Channel.send` and `receive`, `StateFlow.value`, callbacks registered with a library and event buses have no call edge and no flow edge between the two ends.
- **Function values a library supplies**: a parameter of a lambda the library runs, and the result of a library call. An invoke of one has fan-out 0.
- **Elements of collections and other library containers.** A lambda stored in a `List` or `Map` is lost. `iteration` and `destructure` edges exist only for `iterator`, `next` and `componentN` functions declared in the sources.
- **Destructured lambda parameters**, compound assignment to a variable (`x += y` keeps the call, not the flow into `x`), and the `value` parameter of a setter.
- **Reflection, dependency injection and generated wiring.** A binding a compiler plugin generates is not in the sources, so a constructor-injected interface is linked to its implementations only by `cha`.
- **Java sources.** Calls into them are library calls.

## Reading a trace

A trace is a path in the call graph over declarations, shortest first. Each hop is one line:

```
<relpath>:<line>  <caller>  --<edge kind>-->  <callee>
```

- `call [static]` is a direct call. `call [via cha, N candidates]` is a virtual call with N possible targets. `call [via fnValue, fan-out N]` is a call through a function value that N values reach, followed by the flow edges that carry this one to the invoke. `assumedInvoke [lambda passed to …]` is the approximation above.
- Two declarations joined by several call sites show the first, with `(+N more call sites)`.
- The header states how many paths exist within the depth limit, how many are printed, and whether the search stopped early.
- A class as `--to` ends the paths at its constructors. A selector that matches nothing in the sources is matched against library callees, and the path ends at the call.
- `--forward` lists the calls out of the sources that are reachable from a declaration, nearest first.

`bin/altitude-golden` regenerates the traces under `golden/` from each target's manifest and diffs them; `--update` rewrites them.
