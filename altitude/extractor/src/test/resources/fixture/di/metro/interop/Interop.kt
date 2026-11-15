package fixture.di.metro.interop

import dev.zacsweers.metro.DependencyGraph
import me.tatarka.inject.annotations.Inject

@Inject class Foreign

@DependencyGraph
interface InteropGraph {
  val foreign: Foreign
}
