package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.manifest.Manifest
import java.nio.file.Path
import kotlin.system.exitProcess

private const val USAGE =
  "Usage: altitude-extractor resolve --manifest <manifest.json> --out <dir> [--no-compiler-plugins]"

fun main(args: Array<String>) {
  if (args.firstOrNull() != "resolve") fail(USAGE)
  val flags = args.drop(1).filter { it == "--no-compiler-plugins" }
  val options = (args.drop(1) - flags.toSet()).chunked(2).associate { it.first() to it.getOrNull(1) }
  val manifest = options["--manifest"] ?: fail(USAGE)
  val out = options["--out"] ?: fail(USAGE)

  val input = Manifest.read(Path.of(manifest)).toAnalysisInput(compilerPlugins = flags.isEmpty())
  val report = AltitudeSession.open(input).use { ResolveReport(collectCallSites(it)) }
  report.write(Path.of(out))
  println("call-like, hand-written: ${report.callLikeResolved().percent()}% resolved")
  exitProcess(0)
}

private fun fail(message: String): Nothing {
  System.err.println(message)
  exitProcess(2)
}
