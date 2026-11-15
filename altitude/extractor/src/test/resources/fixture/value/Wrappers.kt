package fixture.value

fun sourceList(): List<String> = listOf("s")

fun <T, R> List<T>.mapAll(f: (T) -> R): List<R> = map(f)

fun callerLambdaAfterContentsOfCopiedWrapper() {
  sink(sourceList().mapAll { it }.first())
}

fun w1(v: String) = w2(v)

fun w2(v: String) = w3(v)

fun w3(v: String) = w4(v)

fun w4(v: String) = w5(v)

fun w5(v: String) = v

fun nestedWrappers() {
  val tainted = w1(source())
  val clean = w1("clean")
  sink(tainted)
  sink(clean)
}

fun <T> deferred(f: () -> T): () -> T = { f() }

fun lambdaEscapingCopiedWrapper() {
  val v = source()
  val later = deferred { v }
  sink(later())
}

fun referenceToHolderMember() {
  val h = Holder { it }
  val run = h::run
  sink(run(source()))
}

fun makeList(v: String): List<String> {
  val made = mutableListOf<String>()
  made.add(v)
  if (made.size > 100) return makeList(v)
  return made
}

fun containerReturnedToItsReader() {
  sink(makeList(source()).first())
}

class FakeRoute {
  fun pass(v: String) = v
}

fun production(v: String): String {
  val a = v
  val b = a
  val c = b
  return c
}

fun fakeOrProduction(fake: Boolean) {
  val v = source()
  val out = if (fake) FakeRoute().pass(v) else production(v)
  sink(out)
}
