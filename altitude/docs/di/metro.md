# Metro binding resolution

This spec says how Altitude derives Metro bindings and injection links from source facts alone. It covers Metro as a whole, not only the parts heypenny-backend uses. The analyzer reads `decl`, `annotation`, `supertype`, `call`, `arg` and `node` rows (see `../facts.md`). It never reads Metro's generated code, because the compiler plugin writes that code in IR and leaves no source.

Version read: Metro **1.5.1**. The backend pins `metro = "1.5.1"` in `gradle/libs.versions.toml`. The annotation list below comes from `dev/zacsweers/metro/*.class` in `runtime-jvm-1.5.1.jar`. Semantics come from these pages, read on 2026-11-14:

- https://zacsweers.github.io/metro/latest/dependency-graphs/
- https://zacsweers.github.io/metro/latest/bindings/
- https://zacsweers.github.io/metro/latest/aggregation/
- https://zacsweers.github.io/metro/latest/injection-types/
- https://zacsweers.github.io/metro/latest/interop/
- https://github.com/ZacSweers/metro (source and `CHANGELOG.md`)

All annotations live in package `dev.zacsweers.metro`. This spec writes them bare.

The 1.5.1 runtime holds these annotations: `AppScope`, `Assisted`, `AssistedFactory`, `AssistedInject`, `BindingContainer`, `Binds`, `ClassKey`, `ContributesBinding`, `ContributesIntoMap`, `ContributesIntoSet`, `ContributesTo`, `DefaultBinding`, `DependencyGraph`, `ElementsIntoSet`, `ExposeImplBinding`, `ForScope`, `GraphExtension`, `GraphPrivate`, `Includes`, `Inject`, `IntKey`, `IntoMap`, `IntoSet`, `MapKey`, `Multibinds`, `Named`, `OptionalBinding`, `Origin`, `Provides`, `Qualifier`, `Scope`, `SingleIn`, `StringKey`. Its runtime types are `Provider`, `MembersInjector`, `SuspendProvider` and `SuspendLazy`. Metro uses `kotlin.Lazy` for lazy injection. There is no `@ContributesGraphExtension` in 1.5.1. A contributed extension is a `@GraphExtension` whose `Factory` carries `@ContributesTo`.

## Output rows

Every rule below yields rows of two relations. Both carry `file` and `line`. `line` is the first line of the declaration's `decl.span`, which starts at its first annotation.

**`binding`**: one row per way a graph can supply a key.

| Field | Meaning |
| --- | --- |
| `graph` | FQ name of the graph class the binding belongs to. |
| `type` | FQ type of the key. Type aliases are expanded, `?` marks nullable, type arguments stay, a function type keeps the `(A) -> B` form. |
| `qualifier` | FQ qualifier annotation plus its arguments, e.g. `dev.zacsweers.metro.Named("io")`. Absent when unqualified. |
| `provider` | Decl ID of what supplies the value: a constructor, a function, a property, a parameter or a class. |
| `kind` | One of the kinds named in the rules. |
| `scope` | FQ scope annotation plus its argument, e.g. `dev.zacsweers.metro.SingleIn(dev.zacsweers.metro.AppScope)`. Absent when unscoped. |
| `reachable` | `true` when a root (an accessor, an injector function or a factory) needs the key, directly or through other bindings. |
| `multibinding` | `set` or `map` when the row is one element of a multibinding. `mapKey` then holds the key. |

**`injectionSite`**: one row per value a graph must supply.

| Field | Meaning |
| --- | --- |
| `graph` | As above. |
| `site` | Decl ID of the parameter, accessor or injected member. |
| `type`, `qualifier` | The requested key, after unwrapping (rule M17). |
| `wrapper` | `direct`, `provider`, `lazy`, `providerOfLazy`, `function` or `assistedFactory`. |
| `provider` | The `provider` of the binding the site resolves to. |
| `typeKind` | `class`, `interface`, `abstract`, `function`, `object` or `library` for the requested type. |

**`diUnresolved`**: one row per declaration Metro would reject at compile time, or per feature the analyzer cannot follow. `graph` is absent when no graph applies. `detail` says what to change.

| `reason` | Meaning | Rule |
| --- | --- | --- |
| `missingBinding` | No binding supplies the site's key. | M4–M7 |
| `duplicateBinding` | Two or more bindings supply the key, after M11a. | M11a |
| `notInjectable` | A contributed class has no injectable constructor and is not an `object`. | M5 |
| `ambiguousBoundType` | A contributed class has no `binding<T>()`, no single supertype and no `DefaultBinding`. | M11 |
| `missingMapKey` | An `IntoMap` or `ContributesIntoMap` has no map key annotation. | M12 |
| `duplicateMapKey` | Two entries of one map share a key. | M12 |
| `emptyMultibinding` | A `Multibinds` collection nothing fills, without `allowEmpty = true`. | M12 |
| `scopeMismatch` | A scoped binding sits in, or resolves to, a graph that does not accept its scope. | M8 |
| `unsupportedFeature` | `createDynamicGraph`, or `Inject` on a top-level function with the option off. | M19 |

A consumer→provider link is the pair (`site`, `provider`). Without it, a constructor-injected interface links to its implementations only by `cha`. The analyzer turns each link into a `di` flow from what the provider yields to the site, and each call of a graph accessor into a `di` call edge to its provider (`../facts.md`).

## Discovery

**M1. Graph.** A class or interface with annotation `DependencyGraph` is a graph. Its arguments are `scope` (positional 0), `additionalScopes`, `bindingContainers` and `excludes`.

- Every class in `scope` and `additionalScopes` is a scope key. The graph accepts `SingleIn(<key>)` for each key.
- The graph's supertypes, walked through `supertype`, contribute their members. A supertype needs no annotation. Its abstract members are accessors and its `@Provides` members are providers.
- Row: none for the graph itself. Rule M10 adds the graph as a binding of its own type.

```kotlin
interface AppGraph { val authRoutes: AuthRoutes }
@DependencyGraph(AppScope::class)
abstract class RealAppGraph : AppGraph
```

**M2. Creation.** A call whose target is `createGraph<T>()` or `createGraphFactory<T>()` (in `dev.zacsweers.metro`, file `CreateGraphKt`) names a graph through its type argument. The call is the graph's creation site. A graph without a creation site in main sources is still a graph; mark its rows with `note: "no creation site"`.

```kotlin
val graph = createGraph<RealAppGraph>()
```

**M3. Graph factory.** A nested interface or abstract class annotated `DependencyGraph.Factory` is the graph's factory. Its single abstract function returns the graph.

- A parameter with `Provides` yields kind `instance`. The provider is the parameter ID.
- A parameter with `Includes` yields kind `includes`. What the parameter's type adds depends on what it is:
  - a graph: its abstract accessors only, never its private bindings (kind `includedAccessor`, provider = that accessor's ID)
  - a `BindingContainer`: its `@Provides` and `@Binds`, as if listed in `bindingContainers` (M6)
  - any other class: its public members with no parameters and a non-`Unit` type (kind `includedAccessor`)
- A factory parameter is never an injection site.

```kotlin
@DependencyGraph
interface AppGraph {
  @DependencyGraph.Factory
  fun interface Factory { fun create(@Provides url: String, @Includes net: NetworkGraph): AppGraph }
}
```

**M4. Accessors.** In a graph or its supertypes, an abstract property or an abstract function with no parameters is an accessor. Its type (with any qualifier on the property, the getter or the function) is an injection site with `site` = the property or function ID. Accessors are roots.

- An abstract function with one parameter and return type `Unit` is a member-injection function (rule M16). It is also a root.
- An accessor whose declaration carries `OptionalBinding` and has a default body is optional. If no binding exists, it yields no link and no error.

## Providing bindings

**M5. Constructor injection.** A class with annotation `Inject`, or with exactly one constructor annotated `Inject`, is injectable. The provider is that constructor's `ctor:` ID. Kind `constructorInject`. Every parameter of that constructor is an injection site, except `Assisted` ones.

- With `contributes-as-inject=true`, a class with any `Contributes*` annotation is injectable without `Inject`. With several constructors it still needs `Inject` on one.
- An abstract or sealed class, an interface or an enum is never injectable. A `Contributes{Binding,IntoSet,IntoMap}` class that is neither injectable nor an `object` is a Metro error: emit `diUnresolved` with reason `notInjectable`.
- A scope annotation on the class (rule M8) sets `scope`.
- An injectable class binds only its own type. It binds a supertype only through M7 or M11.
- The binding belongs to every graph that needs it. Emit a row per graph where the class is reachable, with `graph` set to that graph.
- `warn-on-inject-annotation-placement=true` only warns when `Inject` sits on the constructor of a class with one constructor. It changes nothing for the analyzer.

```kotlin
@Inject @SingleIn(AppScope::class)
class DbQueries(private val dbDriver: JdbcDriver)
```

**M6. `@Provides`.** A function or property with annotation `Provides` is a provider. Kind `provides`. Its type key is the return type or property type, with any qualifier on the declaration. Each value parameter is an injection site. Allowed owners:

- the graph or any of its supertypes (also an interface with a default body)
- a companion object of the graph or of a supertype
- an `object` or class annotated `BindingContainer` that the graph lists in `bindingContainers`, takes through `Includes`, or receives through `ContributesTo` (rule M11)

A `private` provider is allowed. With `enable-private-provider-properties=true`, a private `@Provides` property is allowed too. Visibility changes nothing for the analyzer.

```kotlin
@Provides @SingleIn(AppScope::class)
fun provideDriver(dataSource: HikariDataSource): JdbcDriver = dataSource.asJdbcDriver()
```

**M7. `@Binds`.** An abstract function or abstract property with annotation `Binds` and one extension receiver binds the receiver type to the declared type. Kind `binds`. The provider is the decl ID of the binds declaration. The receiver is one injection site, with `site` = `<binds ID>#<recv>`.

- The receiver must be a subtype of the declared type. If `supertype` facts do not show that, emit the row with `confidence: "unsure"`.
- A `@Binds` with no receiver and no parameters binds an injectable class to itself. It adds nothing beyond M5.
- A private `@Binds` that returns `this` behaves the same.

```kotlin
@Binds abstract val RealSecretReader.bind: SecretReader
```

**M8. Scopes.** An annotation is a scope when its class carries `Scope`. `SingleIn(X::class)` is the built-in scope with an argument. A scoped binding gets `scope` set. An unscoped binding gets a new instance per request.

- A graph accepts `SingleIn(K)` and `K` itself for each scope key `K`, and any scope annotation on the graph class.
- A scoped `@Inject` class lives in the nearest graph, from the requesting graph upward, that accepts its scope. A child extension that requests a class of its parent's scope resolves it in the parent and records kind `parentGraph`, so both share one instance.
- If no graph from the requester up accepts the scope, Metro reports `IncompatiblyScopedBindings`. Emit `diUnresolved` with reason `scopeMismatch`, and still link the site. The same holds for a scoped `@Provides`, `@Binds` or contribution in a graph that does not accept its scope.

**M9. Qualifiers.** An annotation is a qualifier when its class carries `Qualifier`. `Named("x")` is built in. The qualifier is part of the key on both sides: the binding's declaration and the injection site's parameter, property or accessor. Two keys match only when type and qualifier both match, arguments included.

- Nullable and non-null are different keys. `Int` does not satisfy `Int?`.
- Type aliases are not keys. Expand them on both sides before matching. `decl.type` keeps the alias; the decl ID shows the expansion.

**M10. The graph itself.** Each graph binds its own type and every supertype that is itself a graph-shaped interface (kind `graph`, provider = the graph's class ID). Code can inject the graph.

## Aggregation

**M11. Contributions.** A class with one of these annotations contributes to the scope key given as argument 0:

- `ContributesTo(X::class)` on an interface: the interface becomes a supertype of every graph with scope key `X`. Apply M4 and M6 to it as if the graph declared it. On a `BindingContainer` it includes the container.
- `ContributesBinding(X::class)`: kind `contributedBinding`. The bound type is the `binding` argument (`binding<T>()`) if present. Otherwise it is the single direct supertype other than `Any`. Otherwise it is `T` from `DefaultBinding<T>` on the nearest supertype that carries it. If none of these applies, Metro reports an error: emit `diUnresolved` with reason `ambiguousBoundType`. A qualifier on the class, or on the type argument of `binding`, joins the key. The provider is the class's injectable constructor (M5), or the object itself.
- `ContributesIntoSet(X::class)`: as above with `multibinding: "set"`.
- `ContributesIntoMap(X::class)`: as above with `multibinding: "map"`. The map key annotation sits on the class or on the `binding` type argument. With neither, emit reason `missingMapKey`.

The `Contributes*` annotations are repeatable. A class contributes once per annotation, each to its own scope.

Arguments that remove a contribution, applied in this order:

1. `excludes = [A::class]` on `DependencyGraph` or `GraphExtension` removes A from that graph only. It also removes a contributed binding container.
2. `replaces = [A::class]` on a contribution removes A's contributions from each graph that receives the replacing contribution. A graph that does not receive it keeps A.
3. **M11a. `priority`**, which follows.

**M11a. Priority.** `priority` exists on `ContributesBinding` and `ContributesIntoMap`. It defaults to `Int.MIN_VALUE`. Among the contributions that remain after `excludes` and `replaces`, group by key: bound type plus qualifier for a binding, and bound type plus map key for a map entry. In each group only the highest priority survives. If two or more share the highest priority, the group stays a duplicate, which Metro reports as an error (emit `duplicateBinding` for a binding, `duplicateMapKey` for a map entry). `ContributesIntoSet` and `ContributesTo` have no priority. Priority never crosses keys, so a contribution bound to another type is untouched. An extension's own binding wins over its parent's by M14, before priority applies.

Contributions work across modules through generated hint interfaces in package `metro.hints`. The analyzer only sees contributions in the modules it loaded. Detect a gap this way: the graph's module depends on a module outside the manifest, and that module ships `metro/hints` classes. Mark such a graph `note: "external contributions possible"`.

```kotlin
@ContributesBinding(AppScope::class)
@Inject class RealCache(private val disk: Disk) : Cache
```

**M12. Multibindings.** Element declarations:

- `IntoSet` on a `@Provides` or `@Binds`: one element of `Set<T>`.
- `ElementsIntoSet` on a `@Provides` returning `Collection<T>`: many elements of `Set<T>`.
- `IntoMap` plus a map key annotation: one entry of `Map<K, V>`. A map key annotation is one whose class carries `MapKey`. The built-in ones are `StringKey`, `IntKey` and `ClassKey`. An `IntoMap` without one is a Metro error: emit reason `missingMapKey`, never a `Map<?, V>` row.
- `Multibinds` on an abstract accessor declares the collection. With `allowEmpty = true` it may be empty. Without it, a collection that nothing fills in the graph or its ancestors is a Metro error: emit reason `emptyMultibinding`.

The key type `K` comes from the map key annotation:

- `MapKey(unwrapValue = true)`, the default: the type of the annotation's single member. `mapKey` is that member's value.
- `MapKey(unwrapValue = false)`: the annotation class itself. `mapKey` is the whole annotation.
- `ClassKey` (`implicitClassKey = true`): `KClass<*>`. Its value defaults to `Nothing::class`, which means the class the annotation sits on.

Two entries of one map with the same key, after M11a, are a Metro error: emit reason `duplicateMapKey`.

Each element is a `binding` row with `type` = the collection type (`kotlin.collections.Set<T>` or `kotlin.collections.Map<K, V>`) and `multibinding` set. An injection site of the collection type links to every element row. A site of a map whose value is wrapped links the same way and records the wrapper (M17):

| Site type | `wrapper` |
| --- | --- |
| `Map<K, Provider<V>>` | `provider` |
| `Map<K, () -> V>` | `function` |
| `Map<K, Lazy<V>>` | `lazy` |
| `Map<K, Provider<Lazy<V>>>` | `providerOfLazy` |

These forms apply to map multibindings only. `Set<Provider<T>>` is not a Metro form; it is the key of a set of providers.

## Graph extensions

**M13. Extension.** A class annotated `GraphExtension(X::class)` is a child graph. Its nested `GraphExtension.Factory` creates it. The parent exposes it in one of four ways:

- an accessor on the parent returning the extension
- an accessor returning its factory
- the parent implementing the factory interface
- `ContributesTo(parentScope)` on the factory, which makes every graph with that scope implement the factory

The parent binds what it exposes: the extension type with kind `graphExtension`, and its factory with kind `graphExtensionFactory`. The provider is the extension's class ID.

**M14. Parent bindings.** An extension sees every binding of its parent, except those marked `GraphPrivate`. It adds its own scope keys. An injection site inside the extension resolves first against its own bindings, then against its ancestors. A binding inherited this way gets kind `parentGraph` and keeps the parent's provider.

```kotlin
@GraphExtension(LoggedInScope::class)
interface LoggedInGraph {
  val feed: Feed
  @ContributesTo(AppScope::class)
  @GraphExtension.Factory interface Factory { fun create(@Provides user: User): LoggedInGraph }
}
```

## Injection forms

**M15. Assisted injection.** A class whose constructor carries `AssistedInject` (or a class with `AssistedInject`) is assisted. Parameters annotated `Assisted` are runtime arguments, not injection sites. The other parameters are injection sites.

- A class or interface annotated `AssistedFactory` with one abstract function returning the assisted class is its factory. It is a binding of kind `assistedFactory`, provider = the factory's class ID.
- Metro matches assisted parameters by name. A Dagger-style `Assisted("id")` identifier is honoured only under Dagger interop.
- With `generate-assisted-factories=true`, Metro generates a nested `Factory` when none exists. Source then holds no factory declaration. Detect this from the compiler option and add a synthetic factory row with `confidence: "unsure"`.
- The assisted class itself is not a binding. Only its factory is.

```kotlin
@AssistedInject
class MePermissions(private val dbQueries: DbQueries, @Assisted private val userId: UserId) {
  @AssistedFactory fun interface Factory { fun create(userId: UserId): MePermissions }
}
```

**M16. Member injection.** A property or function annotated `Inject` in a class body is an injected member. Each is an injection site.

- An injectable class gets its members injected after construction.
- A graph function `fun inject(target: T)` injects T's members. It is a root.
- `MembersInjector<T>` is injectable from any graph. Kind `membersInjector`, provider = T's class ID.

**M17. Wrappers.** An injection site of type `Provider<T>`, `kotlin.Lazy<T>`, `Provider<Lazy<T>>` or `() -> T` requests T. Unwrap it and record `wrapper`.

- Wrappers nest (since Metro 1.4.0): `() -> Lazy<T>` requests T. `wrapper` is `providerOfLazy` for a provider of a lazy, and otherwise the outermost wrapper.
- `() -> T` counts as a provider only with `enable-function-providers=true`, the default since 1.0.0-RC3. Otherwise it is an ordinary key of function type.
- `suspend () -> T`, `SuspendProvider<T>` and `SuspendLazy<T>` count only with `enable-suspend-providers=true`.
- A wrapped site still links to the same provider. The wrapper only changes when the provider runs.

**M18. Default values.** A constructor or `@Provides` parameter with a default value is optional under `optional-binding-behavior=DEFAULT`. If the graph has a binding for its key, link it. If not, emit the site with `provider` absent and `note: "default value"`. Under `REQUIRE_OPTIONAL_BINDING` it is optional only with `OptionalBinding`. Under `DISABLED` it is never optional.

**M19. Top-level function injection.** With `enable-top-level-function-injection=true`, a top-level function annotated `Inject` becomes a generated class named after the function, capitalized. That class is a binding of kind `functionInject`, provider = the function's ID. Its non-assisted parameters are injection sites. With the option off, `Inject` on a top-level function is a compile error: emit reason `unsupportedFeature` and no binding.

**M21. `ExposeImplBinding`.** With `generate-contribution-providers=true`, Metro binds a `Contributes{Binding,IntoSet,IntoMap}` class only as its bound type, so a site that asks for the implementation class finds nothing (`missingBinding`, with `detail` naming the option). `ExposeImplBinding` on the class keeps the implementation injectable too. With the option off, the default, the annotation changes nothing.

## Interop

**M20. Foreign annotations.** Each interop option adds annotations that count the same as Metro's own:

| Option | Adds |
| --- | --- |
| `interop-include-dagger-annotations` | `dagger.Module` as `BindingContainer`; `dagger.Provides`, `dagger.Binds`, `dagger.Component`, `dagger.multibindings.*`, `dagger.assisted.*`, `dagger.BindsOptionalOf` |
| `interop-include-javax-annotations`, `-jakarta-` | `Inject`, `Qualifier`, `Scope`, `Named`, `Singleton`, `Provider` |
| `interop-include-anvil-annotations` | `com.squareup.anvil.annotations.*`: `ContributesTo`, `ContributesBinding`, `ContributesMultibinding` (as `ContributesInto*`), `MergeComponent`. Anvil's `rank` reads as `priority`. |
| `interop-include-kotlin-inject-annotations` | `me.tatarka.inject.annotations.*`: `Inject`, `Provides`, `Component`, `Scope`, `Qualifier`, `IntoSet`, `IntoMap`, `Assisted` |
| `interop-include-kotlin-inject-anvil-annotations` | `software.amazon.lastmile.kotlin.inject.anvil.*`; `ContributesBinding(multibinding = true)` reads as `ContributesIntoSet` |
| `interop-include-hilt-annotations` | Hilt markers; implies Dagger |
| `interop-include-guice-annotations` | `com.google.inject.*`: `Inject`, `Provides`, `Assisted`, `AssistedInject`, `BindingAnnotation`, `ScopeAnnotation`, `MapKey`, `ProvidesIntoSet`, `ProvidesIntoMap` |

Runtime interop (`enable-dagger-runtime-interop`, `enable-guice-runtime-interop`) makes the foreign `Provider` and `Lazy` types count as wrappers in M17. Read the options from the manifest's compiler-plugin arguments. With every option false, apply none of this table.

## Compiler options

The analyzer reads each module's options from the manifest. An option the manifest does not list takes Metro 1.5.1's default (`MetroOptions.kt`):

| Option | Default | Rule |
| --- | --- | --- |
| `contributes-as-inject` | `true` | M5 |
| `enable-function-providers` | `true` | M17 |
| `enable-suspend-providers` | `false` | M17 |
| `optional-binding-behavior` | `DEFAULT` | M18 |
| `generate-assisted-factories` | `false` | M15 |
| `generate-contribution-providers` | `false` | M21 |
| `enable-top-level-function-injection` | `false` | M19 |
| every `interop-*` and `enable-*-runtime-interop` | `false` | M20 |

## Support

Each Metro 1.5.1 feature, and how the analyzer treats it. Tests are in `extractor/src/test/kotlin/.../MetroFixtureTest.kt` and `DiFixtureTest.kt`, over the fixtures in `extractor/src/test/resources/fixture/di/metro/`, which compile against the real runtime.

| Feature | Status | Fixture |
| --- | --- | --- |
| `DependencyGraph`, `scope`, `additionalScopes`, supertype members | Supported | `AppGraph.kt`, `features` |
| `createGraph`, `createGraphFactory`, `DependencyGraph.Factory` with `@Provides` and `@Includes` | Supported | `features` |
| `bindingContainers`, `Includes` between containers | Supported | `features` |
| `ContributesTo` on a `BindingContainer` | Supported | none |
| Accessors, `OptionalBinding` accessors | Supported | `features` |
| `Inject` class and constructor, `contributes-as-inject` | Supported | `features`, `priority` |
| A contributed class that is not injectable | `notInjectable` | `diagnostics` |
| `Provides`, `Binds`, companion and container providers | Supported | `AppGraph.kt`, `features` |
| `Scope`, `SingleIn`, the scope owner in a graph chain | Supported | `extension` |
| A scope no graph accepts | `scopeMismatch` | `diagnostics` |
| `Qualifier`, `Named`, custom qualifiers, `ForScope` | Supported | `features` |
| The graph as a binding of itself | Supported | `AppGraph.kt` |
| `ContributesTo` on an interface | Supported | `features` |
| `ContributesBinding`, `ContributesIntoSet`, `ContributesIntoMap`, `binding<T>()` with a qualifier or map key | Supported | `priority`, `multibind` |
| `DefaultBinding<T>` | Supported | `features` |
| An ambiguous bound type | `ambiguousBoundType` | `diagnostics` |
| `excludes`, `replaces`, `priority` (M11a) | Supported | `priority` |
| Equal priority | `duplicateBinding` | `priority` |
| `IntoSet`, `ElementsIntoSet`, `IntoMap`, `Multibinds(allowEmpty)` | Supported | `multibind` |
| An empty `Multibinds` without `allowEmpty` | `emptyMultibinding` | `diagnostics` |
| `StringKey`, `IntKey`, `ClassKey` with its implicit value, custom `MapKey`, `unwrapValue = false` | Supported | `multibind` |
| A missing or duplicate map key | `missingMapKey`, `duplicateMapKey` | `diagnostics` |
| `Map<K, Provider<V>>`, `Map<K, () -> V>`, `Map<K, Lazy<V>>`, `Map<K, Provider<Lazy<V>>>` | Supported | `multibind` |
| `GraphExtension`, its factory, `ContributesTo` on the factory, `GraphPrivate` | Supported | `extension`, `features` |
| `AssistedInject`, `Assisted`, `AssistedFactory` | Supported | `features` |
| `generate-assisted-factories` | Synthetic `assistedFactory` row, `confidence: "unsure"` | none: source cannot name the generated type |
| `Inject` members, `fun inject(target)`, `MembersInjector<T>` | Supported | `features` |
| `Provider`, `Lazy`, `() -> T`, nested wrappers | Supported | `features` |
| `SuspendProvider`, `SuspendLazy`, `suspend () -> T` | Supported | `suspending` |
| Default parameter values under `optional-binding-behavior=DEFAULT` | Supported | `features` |
| `REQUIRE_OPTIONAL_BINDING`, `DISABLED` | Supported | `features` |
| Top-level function injection | Supported with the option; `unsupportedFeature` without it | `features` |
| `ExposeImplBinding`, `generate-contribution-providers` | Supported | `expose` |
| `createDynamicGraph`, `createDynamicGraphFactory` | `unsupportedFeature` | `diagnostics` |
| kotlin-inject annotation interop | Supported | `interop` |
| Dagger, javax, jakarta, Anvil, kotlin-inject-anvil, Hilt and Guice interop, runtime interop | Supported by annotation name | none: the fixture classpath has no such runtime |
| Contributions from modules outside the manifest (`metro.hints`) | Not detected; the note in M11 is unimplemented | none |
| `Origin`, `asContribution`, graph sharding, switching providers | No effect on links | none |

## What the analyzer can and cannot derive

These follow from source facts, given the compiler options in the manifest:

- every graph, factory, accessor, provider, binds, scope and qualifier in loaded sources
- every injection site and the binding it resolves to, inside loaded sources
- reachability from roots, by a fixpoint over the site→provider links

Source alone cannot derive these. Each has a detection test:

- **External contributions** (M11). Test: a dependency module outside the manifest ships `metro/hints`.
- **Generated factories** (M15) when `generate-assisted-factories=true`. Test: the option is on and an `AssistedInject` class has no nested factory.
- **Bindings from compiled Dagger modules or factories** under runtime interop. Test: the option is on and a key resolves to nothing in source.
- **Which of two equal-priority bindings wins.** Metro reports a duplicate binding at compile time, so there is no answer. Emit `diUnresolved` with reason `duplicateBinding` at each site of the key (M11a).
- **Graphs built at run time.** `createDynamicGraph` and `createDynamicGraphFactory` replace bindings with containers passed at the call. Emit reason `unsupportedFeature` at the call. The graph's static links stay.
- **Bound type inference across library supertypes.** `ContributesBinding` takes the single supertype. A library supertype is not in `supertype` facts when it comes from a superclass outside the sources. Test: the class's superclass is a library class.
- **Values built by hand inside a provider body.** `provideLogger` that calls `ConsoleLogger(...)` itself makes `ConsoleLogger` reachable at runtime but not through DI. The DI link stops at the provider; the call graph covers the rest. Do not mark the hand-built class as a reachable binding.
- **Graph sharding** (`enable-graph-sharding`) and **switching providers** change generated code only. They change no link.
