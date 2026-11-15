package fixture.di.metro.features

import dev.zacsweers.metro.Assisted
import dev.zacsweers.metro.AssistedFactory
import dev.zacsweers.metro.AssistedInject
import dev.zacsweers.metro.BindingContainer
import dev.zacsweers.metro.Binds
import dev.zacsweers.metro.ContributesBinding
import dev.zacsweers.metro.ContributesTo
import dev.zacsweers.metro.DefaultBinding
import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.ForScope
import dev.zacsweers.metro.GraphExtension
import dev.zacsweers.metro.GraphPrivate
import dev.zacsweers.metro.Includes
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.MembersInjector
import dev.zacsweers.metro.Named
import dev.zacsweers.metro.OptionalBinding
import dev.zacsweers.metro.Provider
import dev.zacsweers.metro.Provides
import dev.zacsweers.metro.SingleIn
import dev.zacsweers.metro.createGraphFactory

abstract class FeatureScope private constructor()

abstract class LeafScope private constructor()

typealias Url = String

interface Animal

@DefaultBinding<Animal> interface Pet : Animal

@ContributesBinding(FeatureScope::class) @Inject class Dog : Pet, Comparable<Dog> {
  override fun compareTo(other: Dog): Int = 0
}

interface Contributed {
  @Provides @Named("contributed") fun provideContributed(): Long = 1L
}

@ContributesTo(FeatureScope::class) interface ContributedAccessors : Contributed

@BindingContainer(includes = [InnerContainer::class])
object OuterContainer {
  @Provides fun outer(): Short = 1
}

@BindingContainer
object InnerContainer {
  @Provides fun inner(): Byte = 1
}

class Remote(val host: String) {
  val port: Int get() = 443
}

class Target {
  @Inject lateinit var animal: Animal
}

@AssistedInject
class Downloader(@Named("base") val base: Url, @Assisted val path: String) {
  @AssistedFactory
  fun interface Factory {
    fun create(path: String): Downloader
  }
}

interface Engine

@Inject class RealEngine : Engine

@Inject
class Car(
  val engine: Provider<Engine>,
  val lazyEngine: Lazy<Engine>,
  val nested: () -> Lazy<Engine>,
  val factory: Downloader.Factory,
  val injector: MembersInjector<Target>,
  @ForScope(FeatureScope::class) val scoped: String,
  val optional: Double = 1.0,
  val short: Short,
  val byte: Byte,
  @Named("contributed") val contributed: Long,
  val port: Int,
  val animal: Animal,
)

@GraphExtension(LeafScope::class)
interface LeafGraph {
  val car: Car
  val hidden: Char

  @GraphExtension.Factory
  interface Factory {
    fun create(): LeafGraph
  }
}

@DependencyGraph(FeatureScope::class, bindingContainers = [OuterContainer::class])
interface FeatureGraph {
  val car: Car
  val leaf: LeafGraph.Factory

  @OptionalBinding val missing: Float get() = 0f

  fun inject(target: Target)

  @Binds val RealEngine.bind: Engine

  @Provides @Named("base") fun base(): Url = "https://example.test"

  @Provides @ForScope(FeatureScope::class) fun scoped(): String = "scoped"

  @GraphPrivate @Provides @SingleIn(FeatureScope::class) fun hidden(): Char = 'c'

  @DependencyGraph.Factory
  fun interface Factory {
    fun create(@Provides @Named("host") host: String, @Includes remote: Remote): FeatureGraph
  }
}

@Inject fun Greeting(@Named("base") base: Url, @Assisted name: String): String = base + name

fun features(): FeatureGraph = createGraphFactory<FeatureGraph.Factory>().create("h", Remote("h"))
