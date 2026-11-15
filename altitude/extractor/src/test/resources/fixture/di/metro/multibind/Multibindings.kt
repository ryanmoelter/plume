package fixture.di.metro.multibind

import dev.zacsweers.metro.ClassKey
import dev.zacsweers.metro.ContributesIntoMap
import dev.zacsweers.metro.ContributesIntoSet
import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.ElementsIntoSet
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.IntoMap
import dev.zacsweers.metro.IntoSet
import dev.zacsweers.metro.MapKey
import dev.zacsweers.metro.Multibinds
import dev.zacsweers.metro.Provider
import dev.zacsweers.metro.Provides
import dev.zacsweers.metro.StringKey
import kotlin.reflect.KClass

abstract class MultiScope private constructor()

interface Plugin

@ContributesIntoMap(MultiScope::class)
@StringKey("a")
@Inject
class PluginA : Plugin

@ContributesIntoMap(MultiScope::class)
@ClassKey
@Inject
class PluginB : Plugin

@ContributesIntoSet(MultiScope::class)
@Inject
class SetPlugin : Plugin

enum class Color { RED }

@MapKey annotation class ColorKey(val value: Color)

@MapKey(unwrapValue = false) annotation class PairKey(val name: String, val color: Color)

@Inject
class Consumer(
  val direct: Map<String, Plugin>,
  val providers: Map<String, Provider<Plugin>>,
  val functions: Map<String, () -> Plugin>,
  val lazies: Map<String, Lazy<Plugin>>,
  val providerOfLazies: Map<String, Provider<Lazy<Plugin>>>,
  val providedMap: Provider<Map<String, Provider<Plugin>>>,
  val byClass: Map<KClass<*>, Plugin>,
  val colors: Map<Color, Int>,
  val pairs: Map<PairKey, Int>,
  val set: Set<Plugin>,
  val ints: Set<Int>,
  val empty: Set<String>,
)

@DependencyGraph(MultiScope::class)
interface MultiGraph {
  val consumer: Consumer

  @Provides @IntoMap @StringKey("p") fun provideP(): Plugin = PluginA()

  @Provides @IntoMap @ColorKey(Color.RED) fun red(): Int = 1

  @Provides @IntoMap @PairKey("x", Color.RED) fun pair(): Int = 2

  @Provides @ElementsIntoSet fun ints(): Set<Int> = setOf(1)

  @Provides @IntoSet fun one(): Int = 1

  @Multibinds(allowEmpty = true) val empty: Set<String>
}
