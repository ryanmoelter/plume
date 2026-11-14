package fixture.flow

class Draft(var name: String) {
  fun changeName(to: String) {
    name = to
  }
}

class Store(private val draft: Draft) {
  fun write(block: Draft.() -> Unit) {
    draft.block()
  }

  fun writeWith(block: Draft.(String) -> Unit) {
    block(draft, "x")
  }
}

fun rename(store: Store) {
  store.write { changeName("a") }
  store.writeWith { changeName(it) }
}

fun Draft.withImplicitReceiver(block: Draft.(String) -> Unit) {
  block("implicit")
}

fun renameImplicitly(draft: Draft) {
  draft.withImplicitReceiver { changeName(it) }
}
