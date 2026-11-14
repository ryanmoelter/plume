package fixture.flow

interface Submitter {
  fun submit(value: String): Int
}

class RealSubmitter : Submitter {
  override fun submit(value: String): Int = value.length
}

class FakeSubmitter : Submitter {
  override fun submit(value: String): Int = 0
}

class Sync(private val submitter: Submitter) {
  fun run(): Int = submitter.submit("x")
}

interface Greeter {
  fun greet(): String
}

class English : Greeter {
  override fun greet(): String = "hello"
}

class French : Greeter {
  override fun greet(): String = "bonjour"
}

class Polite(inner: English) : Greeter by inner

fun greetPolitely(): String = Polite(English()).greet()

fun interface Listener {
  fun onEvent(name: String)
}

class Button(private val listener: Listener) {
  fun click() = listener.onEvent("click")
}

fun makeButton(): Button = Button { report(it) }
