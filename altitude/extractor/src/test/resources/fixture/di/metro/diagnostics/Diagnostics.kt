package fixture.di.metro.diagnostics

import dev.zacsweers.metro.ContributesBinding
import dev.zacsweers.metro.ContributesIntoMap
import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.IntoMap
import dev.zacsweers.metro.Multibinds
import dev.zacsweers.metro.Provides
import dev.zacsweers.metro.SingleIn
import dev.zacsweers.metro.StringKey
import dev.zacsweers.metro.createDynamicGraph

abstract class DiagScope private constructor()

abstract class ElsewhereScope private constructor()

interface Service

@ContributesBinding(DiagScope::class)
class TwoConstructors(val id: Int) : Service {
  constructor() : this(0)
}

@ContributesBinding(DiagScope::class) abstract class AbstractService : Service

interface Keyed

@ContributesIntoMap(DiagScope::class) @Inject class Unkeyed : Keyed

@SingleIn(ElsewhereScope::class) @Inject class Misscoped

@DependencyGraph(DiagScope::class)
interface DiagGraph {
  val service: Service
  val keyed: Map<String, Keyed>
  val misscoped: Misscoped

  @Multibinds val nothing: Set<Int>
}

fun dynamic(): DiagGraph = createDynamicGraph<DiagGraph>(Any())

@DependencyGraph
interface DupGraph {
  val numbers: Map<String, Int>

  @Provides @IntoMap @StringKey("a") fun first(): Int = 1

  @Provides @IntoMap @StringKey("a") fun second(): Int = 2
}
