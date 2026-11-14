package fixture.core

class Editor(val edit: (List<String>) -> Unit) {
  fun apply(items: List<String>) {
    edit(items)
  }
}

val String.shout: String
  get() = uppercase()

fun useShout(): String = "a".shout

fun shoutReference() = String::shout
