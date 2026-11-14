package fixture.core

interface Greeter {
  fun greet(): String
}

class English : Greeter {
  override fun greet(): String = "hello"
}

class Polite(inner: Greeter) : Greeter by inner

fun greetPolitely(): String = Polite(English()).greet()

class Config {
  val heavy: String by lazy { "x" }

  fun read(): String = heavy
}
