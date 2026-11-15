package com.ryanmoelter.altitude.rules

import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.AnnotationValueFact
import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Derived
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.facts.SqlStatementFact
import com.ryanmoelter.altitude.facts.SupertypeFact

/** Hand-built facts for the rule tests. Each expression sits on its own line of one file. */
class FactsBuilder(private val file: String = "src/App.kt") {
  private val decls = ArrayList<DeclFact>()
  private val nodes = ArrayList<NodeFact>()
  private val calls = ArrayList<CallFact>()
  private val args = ArrayList<ArgFact>()
  private val flows = ArrayList<FlowFact>()
  private val supertypes = ArrayList<SupertypeFact>()
  private val annotations = ArrayList<AnnotationFact>()
  private val statements = ArrayList<SqlStatementFact>()
  private val files = arrayListOf(FileFact(file, ":", generated = false))

  val index: FactIndex
    get() = FactIndex(Facts(files = files, decls = decls, supertypes = supertypes, annotations = annotations, nodes = nodes, calls = calls, args = args, flows = flows, sqlStatements = statements))

  val noDerived = Derived()

  fun position(line: Int, kind: String, file: String = this.file): String = "$file:$line:1-$line:9:$kind"

  fun decl(sym: String, kind: String, line: Int = 1, type: String? = null, modifiers: List<String> = emptyList(), owner: String? = null, index: Int? = null): String {
    val name = sym.substringBefore('(').substringAfterLast('/').substringAfterLast('.').substringAfterLast('#')
    decls += DeclFact(sym, kind, name, owner ?: "file:$file", file, "$line:1-$line:9", type, modifiers, index = index)
    return sym
  }

  fun node(line: Int, kind: String, type: String? = null, target: String? = null, text: String? = null, scope: String = "fun:app/main()"): String {
    val id = position(line, kind)
    nodes += NodeFact(id, kind, scope, type, target = target, text = text)
    return id
  }

  fun literal(line: Int, value: String): String = node(line, "literal", "kotlin.String", text = "\"$value\"")

  /** Returns the result node. Each argument is the nodes of one parameter. */
  fun call(
    line: Int,
    target: String,
    vararg arguments: List<String>,
    receiver: String? = null,
    extReceiver: String? = null,
    caller: String = "fun:app/main()",
    dispatch: String = "static",
    params: List<String> = emptyList(),
    form: String = "positional",
    type: String? = null,
    file: String = this.file,
  ): String {
    val id = position(line, "call", file)
    val result = position(line, "callResult", file)
    calls += CallFact(id, caller, target, dispatch, receiver = listOfNotNull(receiver), extReceiver = listOfNotNull(extReceiver), result = result)
    nodes += NodeFact(result, "callResult", caller, type, target = id)
    arguments.forEachIndexed { index, same ->
      same.forEach { args += ArgFact(id, "$target#${params.getOrElse(index) { "p$index" }}", index, it, form) }
    }
    return result
  }

  fun flow(from: String, to: String) {
    flows += FlowFact(from, to, "assign", from)
  }

  fun supertype(cls: String, sup: String) {
    supertypes += SupertypeFact(cls, sup)
  }

  fun annotation(sym: String, annFq: String, value: String) {
    annotations += AnnotationFact(sym, annFq, values = listOf(AnnotationValueFact("value", "const", "\"$value\"")))
  }

  fun statement(cls: String, label: String, access: String, line: Int) {
    statements += SqlStatementFact(cls, label, "src/sqldelight/App.sq", line, access)
  }

  fun generatedFile(path: String) {
    files += FileFact(path, ":", generated = true)
  }
}
