package fixture.di.metro.extension

import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.GraphExtension
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn

abstract class ParentScope private constructor()

abstract class ChildScope private constructor()

@SingleIn(ParentScope::class) @Inject class Session

@SingleIn(ChildScope::class) @Inject class Screen(val session: Session)

@GraphExtension(ChildScope::class)
interface ChildGraph {
  val screen: Screen

  @GraphExtension.Factory
  interface Factory {
    fun create(): ChildGraph
  }
}

@DependencyGraph(ParentScope::class)
interface ParentGraph {
  val childFactory: ChildGraph.Factory
}
