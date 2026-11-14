package fixture.models

class Item(val name: String)

fun sink(value: Any?) {}

fun scopes(box: Item): String {
  val viaLet = box.let { it.name }
  val viaApply = box.apply { sink(name) }
  val viaAlso = box.also { seen -> sink(seen) }
  val viaRun = box.run { name }
  val viaWith = with(box) { name }
  sink(viaApply)
  sink(viaAlso)
  return viaLet + viaRun + viaWith
}

fun unmodelled() {
  kotlin.concurrent.thread { sink("x") }
}
