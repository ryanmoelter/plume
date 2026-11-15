package fixture.value

class Holder(private val f: (String) -> String) {
  fun run(x: String) = f(x)
}

fun holderCalledFromOutside() {
  val h = Holder { it }
  sink(h.run(source()))
}

class Setter(private val f: (String) -> Unit) {
  private var last: String = ""

  fun put(x: String) {
    last = x
    f(x)
  }

  fun get(): String = last
}

fun holderWrittenFromOutside() {
  val s = Setter {}
  s.put(source())
  sink(s.get())
}
