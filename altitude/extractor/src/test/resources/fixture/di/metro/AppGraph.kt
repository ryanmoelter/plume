package fixture.di.metro

import dev.zacsweers.metro.AppScope
import dev.zacsweers.metro.Binds
import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.Provides
import dev.zacsweers.metro.SingleIn
import dev.zacsweers.metro.createGraph

class Api(val url: String)

interface Repo {
  fun load(): String
}

@Inject
class RealRepo(private val api: Api) : Repo {
  override fun load(): String = api.url
}

@Inject
class Presenter(val repo: Repo, val api: Lazy<Api>) {
  fun show(): String = repo.load()
}

class Unused

@DependencyGraph(AppScope::class)
interface AppGraph {
  val presenter: Presenter

  @Provides @SingleIn(AppScope::class) fun api(): Api = Api("https://example.test")

  @Provides fun unused(): Unused = Unused()

  @Binds val RealRepo.bind: Repo
}

fun main() {
  val graph = createGraph<AppGraph>()
  graph.presenter.show()
}
