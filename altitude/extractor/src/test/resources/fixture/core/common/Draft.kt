package fixture.core

class Draft(var name: String) {
  fun changeName() {
    name = "changed"
  }
}

class Store(private val draft: Draft) {
  fun write(block: Draft.() -> Unit) {
    draft.block()
  }
}

fun rename(store: Store) {
  store.write { changeName() }
}
