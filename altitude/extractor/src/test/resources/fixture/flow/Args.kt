package fixture.flow

fun report(message: String) {}

fun configure(
  name: String = "default",
  retries: Int = 3,
  vararg tags: String,
  onDone: (String) -> Unit,
) {
  onDone(name)
}

fun useConfigure() {
  configure(retries = 2, tags = arrayOf("a")) { report(it) }
  configure("n", 1, "t1", "t2", onDone = ::report)
}

fun localFunction(): Int {
  fun helper(x: Int): Int = x + 1
  val reference = ::helper
  return reference(1) + helper(2)
}

fun eachReported(values: List<Int>) {
  values.forEach { report(it.toString()) }
}

class Holder {
  var callback: (() -> Unit)? = null

  fun fire() {
    callback?.invoke()
  }
}

fun hold(holder: Holder) {
  holder.callback = { report("held") }
}
