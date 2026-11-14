package fixture.models

fun collections(first: Item, second: Item, stranger: Item): String {
  val items = listOf(first, second)
  val names = items.filter { it.name.isNotEmpty() }.map { mapped -> mapped.name }
  val found = items.firstOrNull { it.name == "a" }
  sink(found)
  for (each in items) sink(each)
  val byName = items.associateBy { it.name }
  val looked = byName["a"]
  sink(looked)
  val others = listOf(stranger)
  val other = others.first()
  sink(other)
  val (left, right) = first to second
  sink(left)
  sink(right)
  return names.joinToString()
}
