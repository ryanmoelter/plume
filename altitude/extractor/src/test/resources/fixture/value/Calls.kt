package fixture.value

fun source(): String = "s"

fun sink(v: String) {}

class G {
  fun other() {}

  fun a(): G {
    other()
    return helper()
  }

  fun helper() = this
}

fun makeG() = G()

fun sinkG(g: G) {}

fun sharedThis() {
  sinkG(makeG().a())
}

fun callIt(g: () -> String): String = g()

fun outer(v: String): String {
  val g = { v }
  return callIt(g)
}

fun capturedThenInvoked() {
  sink(outer(source()))
}

fun later(v: String): () -> String = { v }

fun invokeLater(v: String): String = later(v)()

fun escapedLambda() {
  sink(invokeLater(source()))
}

fun id(v: String): String = v

fun twoCallers() {
  val tainted = id(source())
  val clean = id("clean")
  sink(tainted)
  sink(clean)
}

fun loop(n: Int, v: String): String = if (n == 0) v else loop(n - 1, v)

fun recursion() {
  sink(loop(3, source()))
}

fun d1(v: String) = d2(v)

fun d2(v: String) = d3(v)

fun d3(v: String) = d4(v)

fun d4(v: String) = d5(v)

fun d5(v: String) = d6(v)

fun d6(v: String) = d7(v)

fun d7(v: String) = d8(v)

fun d8(v: String) = v

fun deep() {
  sink(d1(source()))
}
