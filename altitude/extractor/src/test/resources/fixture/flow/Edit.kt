package fixture.flow

class Delta(val name: String)

class Graph(private val edit: (List<Delta>) -> Unit) {
  private val editInGraph: (List<Delta>) -> Unit = edit
  private val data = Data(editInGraph)

  private fun editInGraph(delta: Delta) = editInGraph(listOf(delta))

  fun rename(name: String) = editInGraph(Delta(name))

  fun item(): Item = Item(data)
}

class Data(val editInGraph: (List<Delta>) -> Unit)

abstract class Graphable {
  abstract val data: Data

  val editInGraph: (List<Delta>) -> Unit
    get() = data.editInGraph

  fun editInGraph(delta: Delta) = editInGraph(listOf(delta))
}

class Item(override val data: Data) : Graphable() {
  fun touch() = editInGraph(Delta("touched"))
}

fun toGraph(edit: (List<Delta>) -> Unit): Graph = Graph(edit = edit)

class Queue {
  fun submit(deltas: List<Delta>) {}
}

class Repository(private val queue: Queue) {
  fun real(): Graph = toGraph(edit = { deltas -> queue.submit(deltas) })

  fun fake(): Graph = toGraph {}
}
