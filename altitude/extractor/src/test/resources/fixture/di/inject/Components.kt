package fixture.di.inject

import me.tatarka.inject.annotations.Assisted
import me.tatarka.inject.annotations.Component
import me.tatarka.inject.annotations.Inject
import me.tatarka.inject.annotations.Provides
import me.tatarka.inject.annotations.Scope

@Scope annotation class Singleton

class Clock

@Inject
class Label(@Assisted val text: String, val clock: Clock)

@Inject
class Greeter(val clock: Clock, val label: (String) -> Label)

@Singleton
@Component
abstract class ParentComponent {
  abstract val clock: Clock

  @Provides @Singleton fun clock(): Clock = Clock()
}

@Component
abstract class ChildComponent(@Component val parent: ParentComponent) {
  abstract val greeter: Greeter
}

fun run(child: ChildComponent) {
  child.greeter.label("hi")
}
