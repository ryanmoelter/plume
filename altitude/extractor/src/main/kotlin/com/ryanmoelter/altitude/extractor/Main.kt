package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.facts.FactStore
import com.ryanmoelter.altitude.facts.MetaFact
import com.ryanmoelter.altitude.manifest.Manifest
import com.ryanmoelter.altitude.model.Models
import com.ryanmoelter.altitude.solver.solve
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
    show    --facts <dir> --file <relpath>
  A selector is a symbol ID, or an `Owner.member` suffix that names one declaration.
  A value is `File.kt:LINE:call(name)`, `cell(Owner.name)`, a location ID, or a property, parameter or local.
  facts and solve take --models <dir> to replace the built-in library models.
  """
    .trimIndent()

private val FLAGS = setOf("--no-compiler-plugins", "--forward", "--value")

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
        val facts = AltitudeSession.open(input).use(::extractFacts)
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
        FactStore.writeDerived(out, solve(FactStore.read(out), models()))
        println("facts: ${facts.decls.size} decls, ${facts.calls.size} calls, ${facts.flows.size} flows")
      }
      "solve" -> {
        val dir = Path.of(required("--facts"))
        val derived = solve(FactStore.read(dir), models())
        FactStore.writeDerived(dir, derived)
        println("solved: ${derived.callEdges.size} call edges, ${derived.fnValues.size} fn values")
      }
      "trace" -> {
        val dir = Path.of(required("--facts"))
        val defaults = TraceOptions()
        val tracer =
          Tracer(
            Program(FactStore.read(dir), FactStore.readDerived(dir)),
            TraceOptions(
              maxDepth = options["--max-depth"]?.toInt() ?: defaults.maxDepth,
              alternates = options["--alternates"]?.toInt() ?: defaults.alternates,
              forwardLimit = options["--limit"]?.toInt() ?: defaults.forwardLimit,
            ),
          )
        print(
          when {
            "--value" in flags -> tracer.traceValue(required("--from"), required("--to"), options["--via"]?.split(',').orEmpty())
            "--forward" in flags -> tracer.forward(required("--from"))
            else -> tracer.trace(required("--from"), required("--to"))
          }
        )
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
