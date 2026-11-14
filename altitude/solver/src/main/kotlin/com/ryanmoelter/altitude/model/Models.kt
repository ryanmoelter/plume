package com.ryanmoelter.altitude.model

import java.nio.file.Path
import kotlin.io.path.extension
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.name
import kotlin.io.path.readText
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

/** The format is documented in `altitude/docs/models.md`. */
class ModelEntry(
  val file: String,
  val id: String,
  val matches: List<String>,
  /** The class of the extension receiver the callee must declare, without type arguments. */
  val receiverType: String?,
  val flows: List<EdgeSpec>,
  val triggers: List<EdgeSpec>,
  val invokes: List<InvokeSpec>,
  val cell: String?,
  val writes: List<AccessSpec>,
  val reads: List<AccessSpec>,
) {
  val ruleId: String
    get() = "$file#$id"
}

class EdgeSpec(val from: Port, val to: Port)

class InvokeSpec(
  val lambda: ArgSelector,
  val role: String,
  /** The element ports whose every value runs the lambda. */
  val on: List<Port>,
  /** A type annotation the parameter must carry, such as `androidx/compose/runtime/Composable`. */
  val whenAnnotated: String?,
)

class AccessSpec(val port: Port, val op: String)

sealed interface Base

data object ReceiverBase : Base

data object DispatchReceiverBase : Base

data object ResultBase : Base

/** `arg[2]`, `arg[name]`, `arg[on*]` or `arg[*]`. */
data class ArgSelector(val index: Int?, val name: Regex?) : Base {
  fun matches(argIndex: Int, parameterName: String): Boolean =
    when {
      index != null -> index == argIndex
      name != null -> name.matches(parameterName)
      else -> true
    }
}

sealed interface LambdaPart

/** `param[0]` or, with a null index, `param[*]`. */
data class LambdaParam(val index: Int?) : LambdaPart

data object LambdaReceiver : LambdaPart

data object LambdaReturn : LambdaPart

/** A value location of a call: a base, optionally a part of the lambda there, optionally its element. */
data class Port(val base: Base, val lambda: LambdaPart?, val element: Boolean) {
  companion object {
    private val part = Regex("""([a-zA-Z]+)(?:\[([^\]]+)])?""")

    fun parse(text: String): Port {
      val parts = text.trim().split('.').map { part.matchEntire(it) ?: error("bad port `$text`") }
      var index = 0
      fun next(): MatchResult? = parts.getOrNull(index)
      val first = next() ?: error("empty port")
      val base: Base =
        when (first.groupValues[1]) {
          "receiver" -> ReceiverBase
          "dispatchReceiver" -> DispatchReceiverBase
          "result" -> ResultBase
          "arg" -> argSelector(first.groupValues[2], text)
          else -> error("bad port `$text`")
        }
      index++
      var lambda: LambdaPart? = null
      val second = next()
      if (second != null && second.groupValues[1] != "element") {
        require(base is ArgSelector) { "only an argument has lambda parts: `$text`" }
        lambda =
          when (second.groupValues[1]) {
            "param" -> LambdaParam(second.groupValues[2].takeUnless { it == "*" }?.toInt())
            "receiver" -> LambdaReceiver
            "return" -> LambdaReturn
            else -> error("bad port `$text`")
          }
        index++
      }
      val element = next()?.groupValues?.get(1) == "element"
      if (element) index++
      require(index == parts.size) { "bad port `$text`" }
      return Port(base, lambda, element)
    }

    fun argSelector(selector: String, text: String): ArgSelector {
      require(selector.isNotEmpty()) { "`arg` needs an index or a name: `$text`" }
      selector.toIntOrNull()?.let { return ArgSelector(it, null) }
      if (selector == "*") return ArgSelector(null, null)
      val pattern = selector.split('*').joinToString(".*") { Regex.escape(it) }
      return ArgSelector(null, Regex(pattern))
    }
  }
}

/** Every model entry, indexed by the callee keys it matches. */
class Models(val entries: List<ModelEntry>) {
  private val exact = HashMap<String, MutableList<ModelEntry>>()
  private val prefixes = ArrayList<Pair<String, ModelEntry>>()

  init {
    val ids = HashSet<String>()
    for (entry in entries) {
      require(ids.add(entry.ruleId)) { "duplicate model entry ${entry.ruleId}" }
      for (match in entry.matches) {
        if (match.endsWith("**")) prefixes += match.removeSuffix("**") to entry
        else exact.getOrPut(match) { ArrayList() } += entry
      }
    }
    prefixes.sortWith(compareBy({ -it.first.length }, { it.first }, { it.second.ruleId }))
  }

  /**
   * The entry for a call of [target]: one that names its full ID, else one that names its key (the
   * ID without parameter and receiver types), else the longest matching `**` prefix.
   */
  fun match(target: String): ModelEntry? {
    val key = calleeKey(target)
    val receiver = receiverClass(target)
    fun accepts(entry: ModelEntry) = entry.receiverType == null || entry.receiverType == receiver
    exact[target]?.firstOrNull(::accepts)?.let { return it }
    exact[key]?.firstOrNull(::accepts)?.let { return it }
    return prefixes.firstOrNull { key.startsWith(it.first) && accepts(it.second) }?.second
  }

  companion object {
    private val ACCESSOR = Regex("""#<(get|set)>$""")
    private const val RESOURCE_DIR = "altitude-models"
    private val INVOKE_KEYS = setOf("lambda", "role", "perValueOf", "whenAnnotated")

    val EMPTY = Models(emptyList())

    /** `fun:kotlin/collections/map@kotlin/collections/Iterable<T>(…)` is `fun:kotlin/collections/map`. */
    fun calleeKey(target: String): String {
      val accessor = ACCESSOR.find(target)?.value.orEmpty()
      val head = target.removeSuffix(accessor)
      val end = head.indexOfFirst { it == '@' || it == '(' }
      return (if (end < 0) head else head.substring(0, end)) + accessor
    }

    /** The class of the extension receiver in a callee ID, without type arguments or `?`. */
    fun receiverClass(target: String): String? {
      val at = target.indexOf('@').takeIf { it >= 0 } ?: return null
      val rest = target.substring(at + 1)
      val end = rest.indexOfFirst { it == '<' || it == '(' || it == '?' || it == '#' }
      return if (end < 0) rest else rest.substring(0, end)
    }

    /** The model files built into the solver from `altitude/models`. */
    fun bundled(): Models {
      val loader = Models::class.java.classLoader
      val index =
        loader.getResourceAsStream("$RESOURCE_DIR/index.txt")?.bufferedReader()?.readLines()
          ?: return EMPTY
      return Models(
        index.filter { it.isNotBlank() }.sorted().flatMap { name ->
          val text = loader.getResourceAsStream("$RESOURCE_DIR/$name")!!.bufferedReader().readText()
          parse(name, text)
        }
      )
    }

    fun load(directory: Path): Models =
      Models(
        directory
          .listDirectoryEntries()
          .filter { it.extension == "yaml" }
          .sortedBy { it.name }
          .flatMap { parse(it.name, it.readText()) }
      )

    fun parse(file: String, text: String): List<ModelEntry> {
      val root = Yaml(SafeConstructor(LoaderOptions())).load<Any?>(text) as? Map<*, *> ?: return emptyList()
      val entries = root["entries"] as? List<*> ?: return emptyList()
      return entries.map { raw ->
        val map = raw as Map<*, *>
        val id = map["id"] as? String ?: error("$file: an entry has no id")
        val known = setOf("id", "match", "receiver", "flows", "triggers", "invokes", "cell", "writes", "reads")
        (map.keys - known).firstOrNull()?.let { error("$file#$id: unknown key `$it`") }
        try {
          ModelEntry(
            file = file,
            id = id,
            matches = strings(map["match"]).also { require(it.isNotEmpty()) { "no match" } },
            receiverType = map["receiver"] as String?,
            flows = strings(map["flows"]).map(::edge),
            triggers = strings(map["triggers"]).map(::edge),
            invokes =
              maps(map["invokes"]).map {
                (it.keys - INVOKE_KEYS).firstOrNull()?.let { key -> error("unknown key `$key` in invokes") }
                InvokeSpec(
                  lambda = Port.parse(it["lambda"] as String).base as ArgSelector,
                  role = it["role"] as String,
                  on = strings(it["perValueOf"]).map(Port::parse),
                  whenAnnotated = it["whenAnnotated"] as String?,
                )
              },
            cell = map["cell"] as String?,
            writes = maps(map["writes"]).map(::access),
            reads = maps(map["reads"]).map(::access),
          )
        } catch (e: RuntimeException) {
          throw IllegalArgumentException("$file#$id: ${e.message}", e)
        }
      }
    }

    private fun edge(text: String): EdgeSpec {
      val sides = text.split("->")
      require(sides.size == 2) { "an edge is `<port> -> <port>`: `$text`" }
      return EdgeSpec(Port.parse(sides[0]), Port.parse(sides[1]))
    }

    private fun access(map: Map<*, *>): AccessSpec {
      val port = Port.parse(map["port"] as String)
      require(port.element) { "a read or write names an element port" }
      return AccessSpec(port, map["op"] as String)
    }

    private fun strings(value: Any?): List<String> =
      when (value) {
        null -> emptyList()
        is String -> listOf(value)
        is List<*> -> value.map { it as String }
        else -> error("expected a string or a list of strings, got $value")
      }

    private fun maps(value: Any?): List<Map<*, *>> =
      (value as List<*>?).orEmpty().map { it as Map<*, *> }
  }
}
