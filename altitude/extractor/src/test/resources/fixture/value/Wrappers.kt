package fixture.value

fun sourceList(): List<String> = listOf("s")

fun <T, R> List<T>.mapAll(f: (T) -> R): List<R> = map(f)

fun callerLambdaAfterContentsOfCopiedWrapper() {
  sink(sourceList().mapAll { it }.first())
}

fun <T> w1(f: () -> T) = w2(f)

fun <T> w2(f: () -> T) = w3(f)

fun <T> w3(f: () -> T) = f()

fun wrappersNestedTwoDeep() {
  val v = source()
  val tainted = w2 { v }
  val clean = w2 { "clean" }
  sink(tainted)
  sink(clean)
}

fun wrappersNestedThreeDeep() {
  val v = source()
  sink(w1 { v })
}

fun <T> x1(f: () -> T) = x2(f)

fun <T> x2(f: () -> T) = x3(f)

fun <T> x3(f: () -> T) = x4(f)

fun <T> x4(f: () -> T) = x5(f)

fun <T> x5(f: () -> T) = f()

fun wrappersNestedDeeperThanTheyAreCopied() {
  val v = source()
  sink(x1 { v })
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
