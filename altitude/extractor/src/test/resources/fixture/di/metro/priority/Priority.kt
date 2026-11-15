package fixture.di.metro.priority

import dev.zacsweers.metro.ContributesBinding
import dev.zacsweers.metro.ContributesIntoMap
import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.StringKey

abstract class PriorityScope private constructor()

abstract class OtherScope private constructor()

interface Store

@ContributesBinding(PriorityScope::class) @Inject class LowStore : Store

@ContributesBinding(PriorityScope::class, priority = 10) @Inject class HighStore : Store

interface Cache

@ContributesBinding(PriorityScope::class)
@ContributesBinding(OtherScope::class)
@Inject
class OldCache : Cache

@ContributesBinding(PriorityScope::class, replaces = [OldCache::class]) @Inject class NewCache : Cache

interface Clock

@ContributesBinding(PriorityScope::class) @Inject class SystemClock : Clock

@ContributesBinding(PriorityScope::class) @Inject class FakeClock : Clock

interface Handler

@ContributesIntoMap(PriorityScope::class) @StringKey("h") @Inject class LowHandler : Handler

@ContributesIntoMap(PriorityScope::class, priority = 1) @StringKey("h") @Inject class HighHandler : Handler

@ContributesIntoMap(PriorityScope::class) @StringKey("other") @Inject class OtherHandler : Handler

interface Logger

@ContributesBinding(PriorityScope::class) @Inject class LoggerA : Logger

@ContributesBinding(PriorityScope::class) @Inject class LoggerB : Logger

@Inject
class Uses(
  val store: Store,
  val cache: Cache,
  val clock: Clock,
  val handlers: Map<String, Handler>,
  val logger: Logger,
)

@DependencyGraph(PriorityScope::class, excludes = [FakeClock::class])
interface PriorityGraph {
  val uses: Uses
}

@DependencyGraph(OtherScope::class)
interface OtherGraph {
  val cache: Cache
}
