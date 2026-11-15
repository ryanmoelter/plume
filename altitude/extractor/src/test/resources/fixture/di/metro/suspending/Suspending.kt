package fixture.di.metro.suspending

import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SuspendLazy
import dev.zacsweers.metro.SuspendProvider

@Inject class Engine

@Inject
class Starter(
  val provided: SuspendProvider<Engine>,
  val lazy: SuspendLazy<Engine>,
  val function: suspend () -> Engine,
)

@DependencyGraph
interface SuspendGraph {
  val starter: Starter
}
