package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.export.BranchRoot
import com.ryanmoelter.altitude.export.Exporter
import com.ryanmoelter.altitude.export.BranchTables
import com.ryanmoelter.altitude.export.BranchesExport
import com.ryanmoelter.altitude.export.defaultStops
import com.ryanmoelter.altitude.export.export
import com.ryanmoelter.altitude.export.exportJson
import com.ryanmoelter.altitude.trace.Direction
import com.ryanmoelter.altitude.facts.FactStore
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.manifest.Manifest
import com.ryanmoelter.altitude.model.Models
import com.ryanmoelter.altitude.rules.EntryTrace
import com.ryanmoelter.altitude.rules.Rules
import com.ryanmoelter.altitude.rules.analyze
import com.ryanmoelter.altitude.rules.check
import com.ryanmoelter.altitude.trace.Program
import com.ryanmoelter.altitude.trace.TraceOptions
import com.ryanmoelter.altitude.trace.Tracer
import java.nio.file.Path
import kotlin.system.exitProcess

private val USAGE =
  """
  Usage: altitude-extractor <command>
    resolve --manifest <manifest.json> --out <dir> [--no-compiler-plugins]
    facts   --manifest <manifest.json> --out <dir> [--no-compiler-plugins]
    solve   --facts <dir>
    trace   --facts <dir> --from <selector> --to <selector> [--max-depth N] [--alternates N]
    trace   --facts <dir> --from <selector> --forward [--max-depth N] [--limit N]
    trace   --facts <dir> --value --from <value> --to <value> [--via <value>,<value>]
    trace   --facts <dir> --from-entrypoint <entry> --to-boundary <boundary> [--max-depth N] [--alternates N]
    branches --facts <dir> (--from <value> | --to <value>) [--through-cells] [--clean] [--json]
    show    --facts <dir> --file <relpath>
    check   --facts <dir> --expected <golden expected dir>
    export  --facts <dir> --out <dir> --target <name> [--golden <golden target dir>] [--split]
  A selector is a symbol ID, or an `Owner.member` suffix that names one declaration.
  A value is `File.kt:LINE:call(name)`, `cell(Owner.name)`, a location ID, or a property, parameter or local.
  An entry is a route path (`/graphql`), `METHOD /path`, a resolver field, a screen class or a selector.
  A boundary is a label, op, kind, `system:kind` or a selector for its target.
  facts and solve take --models <dir> to replace the built-in library models.
  """
    .trimIndent()

private val FLAGS = setOf("--no-compiler-plugins", "--forward", "--value", "--split", "--through-cells", "--clean", "--json")

fun main(args: Array<String>) {
  val command = args.firstOrNull() ?: fail(USAGE)
  val flags = args.drop(1).filter { it in FLAGS }.toSet()
  val options = args.drop(1).filter { it !in FLAGS }.chunked(2).associate { it.first() to it.getOrNull(1) }
  fun required(name: String): String = options[name] ?: fail(USAGE)
  fun models(): Models = options["--models"]?.let { Models.load(Path.of(it)) } ?: Models.bundled()

  // The session leaves non-daemon threads behind, so every path out names its exit code.
  try {
    when (command) {
      "resolve" -> {
        val input = analysisInput(required("--manifest"), flags)
        val report = AltitudeSession.open(input).use { ResolveReport(collectCallSites(it)) }
        report.write(Path.of(required("--out")))
        println("call-like, hand-written: ${report.callLikeResolved().percent()}% resolved")
      }
      "facts" -> {
        val manifest = Manifest.read(Path.of(required("--manifest")))
        val input = manifest.toAnalysisInput(compilerPlugins = "--no-compiler-plugins" !in flags)
        val out = Path.of(required("--out"))
        val facts =
          AltitudeSession.open(input)
            .use(::extractFacts)
            .copy(sqlStatements = manifest.sqlStatements(), pluginOptions = manifest.pluginOptions())
        val meta =
          MetaFact(
            gitSha = manifest.git?.sha,
            gitDirty = manifest.git?.dirty,
            manifestKotlinFiles = input.modules.sumOf { m -> m.sources.count { it.isKotlin } },
            loadedKotlinFiles = facts.files.size,
            filesWithSyntaxErrors = facts.files.count { it.syntaxErrors > 0 },
            duplicateDeclIds = facts.decls.groupingBy { it.sym }.eachCount().count { it.value > 1 },
          )
        FactStore.write(out, facts, meta)
        // Solving what was read back keeps `facts` and a later `solve` byte-identical.
        val analysis = analyze(FactStore.read(out), models())
        FactStore.writeDerived(out, analysis.derived)
        analysis.rules.write(out)
        println("facts: ${facts.decls.size} decls, ${facts.calls.size} calls, ${facts.flows.size} flows")
      }
      "solve" -> {
        val dir = Path.of(required("--facts"))
        val analysis = analyze(FactStore.read(dir), models())
        val derived = analysis.derived
        FactStore.writeDerived(dir, derived)
        analysis.rules.write(dir)
        println("solved: ${derived.callEdges.size} call edges, ${derived.fnValues.size} fn values")
      }
      "trace" -> {
        val dir = Path.of(required("--facts"))
        val program = Program(FactStore.read(dir), FactStore.readDerived(dir))
        val defaults = TraceOptions()
        val tracer =
          Tracer(
            program,
            TraceOptions(
              maxDepth = options["--max-depth"]?.toInt() ?: defaults.maxDepth,
              alternates = options["--alternates"]?.toInt() ?: defaults.alternates,
              forwardLimit = options["--limit"]?.toInt() ?: defaults.forwardLimit,
            ),
          )
        print(
          when {
            "--from-entrypoint" in options ->
              EntryTrace(program, Rules.read(dir), tracer).trace(required("--from-entrypoint"), required("--to-boundary"))
            "--value" in flags ->tracer.traceValue(required("--from"), required("--to"), options["--via"]?.split(',').orEmpty())
            "--forward" in flags -> tracer.forward(required("--from"))
            else -> tracer.trace(required("--from"), required("--to"))
          }
        )
      }
      "branches" -> {
        val dir = Path.of(required("--facts"))
        val (context, memberIds) = Exporter("branches", FactStore.read(dir), FactStore.readDerived(dir), Rules.read(dir), FactStore.readMeta(dir)).branchContext()
        val direction = if ("--to" in options) Direction.BACKWARD else Direction.FORWARD
        val selector = if (direction == Direction.FORWARD) required("--from") else required("--to")
        val selection = context.program.selectValue(selector, goal = direction == Direction.BACKWARD)
        if (selection.locations.isEmpty()) fail("${if (direction == Direction.FORWARD) "--from" else "--to"} ${selection.label}: nothing matches.")
        val root = BranchRoot(direction, "value", null, selection.label, selection.locations)
        val clean = "--clean" in flags
        val tree = context.tree(root, defaultStops(direction, "--through-cells" in flags), clean)
        if ("--json" in flags) {
          val tables = BranchTables()
          val out = context.out(root, tree, clean, tables).main
          println(exportJson.encodeToString(BranchesExport.serializer(), tables.export("", listOf(out), emptyList(), emptyMap())))
        }
        else print(context.text(root, tree, memberIds))
      }
      "check" -> {
        val result = check(Path.of(required("--facts")), Path.of(required("--expected")))
        print(result.text)
        if (result.differences > 0) exitProcess(1)
      }
      "export" -> {
        val result =
          export(
            Path.of(required("--facts")),
            Path.of(required("--out")),
            required("--target"),
            options["--golden"]?.let { Path.of(it) },
            split = "--split" in flags,
          )
        for ((name, bytes) in result.files) println("$name: $bytes bytes")
      }
      "show" -> {
        val dir = Path.of(required("--facts"))
        print(Tracer(Program(FactStore.read(dir), FactStore.readDerived(dir))).show(required("--file")))
      }
      else -> fail(USAGE)
    }
  } catch (e: Throwable) {
    e.printStackTrace()
    exitProcess(1)
  }
  exitProcess(0)
}

private fun analysisInput(manifest: String, flags: Set<String>): AnalysisInput =
  Manifest.read(Path.of(manifest)).toAnalysisInput(compilerPlugins = "--no-compiler-plugins" !in flags)

private val SourceInput.isKotlin: Boolean
  get() = path.toString().endsWith(".kt")

private fun fail(message: String): Nothing {
  System.err.println(message)
  exitProcess(2)
}
