# kotlin-inject binding resolution

This spec says how Altitude derives kotlin-inject bindings and injection links from source facts. heypenny-app uses kotlin-inject in `:app` and `:shared`. The output rows are the `binding` and `injectionSite` relations of `metro.md`, with the same fields.

Version read: kotlin-inject **0.9.0** with its KSP processor (`me.tatarka.inject:kotlin-inject-compiler-ksp`). The app pins `kotlinInject = "0.9.0"`. Sources, read on 2026-11-14:

- https://github.com/evant/kotlin-inject (README)
- https://github.com/evant/kotlin-inject/blob/main/docs/ (advanced usage, multiplatform)
- The KSP output in the app checkout, `app/build/generated/ksp/debug/` and `shared/build/generated/ksp/metadata/commonMain/`, which shows what the processor did with these sources.

All annotations live in `me.tatarka.inject.annotations`. This spec writes them bare. Unlike Metro, kotlin-inject runs in KSP and writes Kotlin source. The analyzer still derives bindings from hand-written source. The generated `Inject<Component>` classes are the oracle for tests, not an input.

## Discovery

**K1. Component.** An abstract class annotated `Component` is a component. An interface cannot be one, but a component's supertypes may be interfaces that declare its accessors and providers.

- Every abstract property and every abstract function without parameters, declared on the component or a supertype, is an accessor and a root.
- Creation: the processor generates `KClass<C>.create(...)` with the component's constructor parameters. A call to `C::class.create(...)` is the creation site. Facts show it as an unresolved call or a call into `gen/`; match it by the `C::class` receiver.

```kotlin
@Component @Singleton
abstract class RealAppComponent(@get:Provides val sqlDriverFactory: DriverFactory) : AppComponent
```

**K2. Component scope.** A scope annotation is one whose class carries `Scope`. A component has a scope when its class carries one, or when a supertype does. RealSharedComponent has `SharedSingleton` only through `interface SharedComponent`. A scoped binding needs a component with the same scope, on itself or on an ancestor (K4).

**K3. Constructor parameters.** Each parameter of the component's primary constructor is one of these:

- `@get:Provides val x: T` (or `@Provides val`): kind `instance`, provider = the parameter's property ID.
- `@Component val parent: P`: a parent component (K4). It is not a binding of type P unless also marked `Provides`.
- any other parameter: plain constructor data. It is not a binding.

A default argument (`= RealSharedComponent::class.create(...)`) does not change the parameter's role.

**K4. Parent components.** A `@Component val` parameter makes its type a parent. A key the child cannot supply resolves against the parent's bindings, recursively.

- If the parent type is an interface, only its accessors are visible. The generated child calls `parent.accessor`. Row kind `parentComponent`, provider = the accessor's ID.
- If the parent type is a component class, its providers are visible too. The generated child calls the parent's `@Provides` function directly (`injector.provideJson()`) and caches scoped values in the parent's `_scoped` map. Row kind `parentComponent`, provider = the parent provider's ID, scope = the parent's scope.
- When the parent has both an accessor and a provider for a key, the child calls the accessor. Use the accessor's ID as provider.
- An `override val` instance property satisfies an accessor of a supertype. It is reachable whenever that accessor is.
- Emit a `parentComponent` row only for keys a child site actually needs.

## Providing bindings

**K5. `@Inject` class.** A class annotated `Inject`, or whose primary constructor carries `Inject`, is injectable. Kind `constructorInject`, provider = the constructor ID. Each constructor parameter is an injection site, except `Assisted` ones. A scope annotation on the class makes it scoped. The class binds only its own type.

**K6. `@Provides` function.** A function annotated `Provides` on a component or a supertype is a provider. Kind `provides`. The key is the return type plus any qualifier. Each parameter is an injection site. A function body may live on an interface. An abstract `@Provides` is not allowed.

**K7. `@Provides` extension property.** A property with receiver and a getter annotated `Provides` binds the property type, supplied from the receiver. Kind `provides`, provider = the property ID. The receiver is one injection site, `site` = `<prop ID>#<recv>`. This is kotlin-inject's form of `@Binds`.

```kotlin
val RealClock.bind: Clock
  @Provides get() = this
```

The annotation sits on the getter. A scope on the getter (`@Singleton @Provides get()`) scopes the binding. `annotation` facts must carry getter annotations for this rule to work.

**K8. Qualifiers.** An annotation whose class carries `Qualifier` joins the key, as in Metro M9. kotlin-inject also treats **each type alias as a distinct key**. `typealias Token = String` and `String` do not match. This differs from Metro: do not expand aliases when matching kotlin-inject keys. heypenny-app has no qualifiers and no aliased keys.

**K9. Multibindings.** `IntoSet` on a `@Provides` function or extension property adds one element to `Set<T>`. `IntoMap` on a provider returning `Pair<K, V>` adds one entry to `Map<K, V>`. A site of type `Set<T>` links to every element row of that component and its ancestors. kotlin-inject has no `@Multibinds`; an empty set is an error unless the site has a default.

```kotlin
val SyncTracker.cacheable: SharedSessionCacheable
  @Provides @IntoSet get() = this
```

## Injection forms

**K10. Function types.** A site of type `() -> T` is a provider of T (`wrapper: "function"`). A site of type `(A, B) -> T` is an assisted factory for T: kotlin-inject calls T's constructor with A and B for its `Assisted` parameters, in order. The link goes to T's constructor.

```kotlin
@Inject class ScreenLogger(private val logger: Logger, @Assisted val screenName: String)
@Inject class RealPremiumManager(private val getScreenLogger: (String) -> ScreenLogger)
```

An accessor of function type (`val screenLogger: (String) -> ScreenLogger`) works the same way.

**K11. `Lazy`.** A site of type `kotlin.Lazy<T>` requests T, `wrapper: "lazy"`.

**K12. Assisted.** `Assisted` marks a constructor parameter supplied by the caller. 0.9.0 also has `AssistedFactory` on an interface with one function returning the class. Without it, the function-type form of K10 is the factory.

**K13. Defaults.** A constructor or provider parameter with a default value uses the default when no binding exists. If a binding exists, link it. If not, emit the site with no provider and `note: "default value"`.

**K14. Generic and nullable keys.** Type arguments are part of the key. `T?` and `T` are different keys.

## Reachability

A binding is reachable when a root of its component needs it, directly or through other bindings, or when a child component's reachable site resolves to it. A `@Provides` that no site needs is still a row, with `reachable: false`. An `@Inject` class is a row only for components where it is reachable, because it belongs to no component until something asks for it.

A provider that builds an object by hand ends the DI link. In `provideLogger(postHogLogger: PostHogLogger, consoleLogger: ConsoleLogger)` both parameters are sites, so both classes are reachable. In a provider that calls `FakeRestApi()` in its body, `FakeRestApi` is not a binding.

## What source cannot derive

- **The generated `create` function.** Only its call site is in source. K1 matches it by receiver.
- **Bindings from a component compiled in another module.** kotlin-inject resolves across modules only through parent components, whose source the analyzer loads if the module is in the manifest. Test: a parent type with no `decl` row.
- **Getter and use-site annotations** are missing from `annotation` facts today: `@Provides get()`, `@get:Provides` on a constructor property, and `@IntoSet` on a getter. Until facts carry them, K3, K7 and K9 cannot fire. Test: a component with zero `Provides` annotations on getters but extension properties named `bind` or `cacheable`.
