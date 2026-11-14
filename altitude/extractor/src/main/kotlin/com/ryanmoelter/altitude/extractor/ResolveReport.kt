package com.ryanmoelter.altitude.extractor

import java.nio.file.Path
import java.util.Locale
import kotlin.io.path.createDirectories
import kotlin.io.path.writeText
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

private const val TOP_UNRESOLVED = 40
private const val EXAMPLES_PER_GROUP = 3

private val siteOrder =
  compareBy<CallSite>({ it.path }, { it.line }, { it.column }, { it.site }, { it.text })

/**
 * Summarizes how much of the code resolved. Every path is relative to the repository and the
 * output carries no timestamp, so two runs over the same input write identical files.
 */
class ResolveReport(sites: List<CallSite>) {
  val sites: List<CallSite> = sites.sortedWith(siteOrder)

  fun callLikeResolved(module: String? = null, generated: Boolean = false): Ratio =
    ratio(sites.filter { it.site.callLike && it.generated == generated && it.inModule(module) })

  fun write(outDir: Path) {
    outDir.createDirectories()
    outDir.resolve("resolve-report.txt").writeText(text())
    outDir.resolve("unresolved.jsonl").writeText(unresolvedJsonl())
  }

  fun text(): String = buildString {
    appendLine("Altitude resolve report")
    appendLine(
      "Call-like sites are calls, constructor calls, operators, array accesses, property " +
        "names, callable references and property delegates."
    )
    appendLine()
    appendSummary("overall", null)
    for (module in sites.map { it.module }.distinct().sorted()) appendSummary("module $module", module)
    appendTopUnresolved("hand-written", generated = false)
    appendTopUnresolved("generated", generated = true)
  }

  fun unresolvedJsonl(): String =
    sites
      .filter { !it.target.resolved }
      .joinToString("") { site ->
        buildJsonObject {
            put("path", site.path)
            put("line", site.line)
            put("column", site.column)
            put("module", site.module)
            put("generated", site.generated)
            put("site", site.site.name)
            put("text", site.text)
            put("target", site.target.name)
            site.diagnostic?.let { put("diagnostic", it) }
            site.symbol?.let { put("candidate", it) }
          }
          .toString() + "\n"
      }

  private fun StringBuilder.appendSummary(title: String, module: String?) {
    val inScope = sites.filter { it.inModule(module) }
    appendLine("== $title ==")
    appendLine(row("", "hand-written", "", "", "generated", "", ""))
    appendLine(row("", "total", "resolved", "pct", "total", "resolved", "pct"))
    appendRatioRow("call-like", inScope.filter { it.site.callLike })
    for (site in Site.entries.filter { it.callLike }) {
      appendRatioRow("  ${site.name.lowercase()}", inScope.filter { it.site == site })
    }
    for (site in Site.entries.filterNot { it.callLike }) {
      appendRatioRow(site.name.lowercase(), inScope.filter { it.site == site })
    }
    appendLine()
    appendTally("call-like targets, hand-written", inScope.handWrittenCallLike()) { it.target.name }
    appendTally(
      "unresolved call-like by diagnostic, hand-written",
      inScope.handWrittenCallLike().filter { !it.target.resolved },
    ) {
      it.diagnostic ?: "none"
    }
  }

  private fun StringBuilder.appendRatioRow(label: String, group: List<CallSite>) {
    val (generated, handWritten) = group.partition { it.generated }
    val left = ratio(handWritten)
    val right = ratio(generated)
    appendLine(
      row(
        label,
        left.total.toString(),
        left.resolved.toString(),
        left.percent(),
        right.total.toString(),
        right.resolved.toString(),
        right.percent(),
      )
    )
  }

  private fun StringBuilder.appendTally(
    title: String,
    group: List<CallSite>,
    key: (CallSite) -> String,
  ) {
    appendLine("$title:")
    val counts = group.groupingBy(key).eachCount()
    for ((name, count) in counts.entries.sortedWith(compareBy({ -it.value }, { it.key }))) {
      appendLine("  %-44s %8d".format(Locale.ROOT, name, count))
    }
    appendLine()
  }

  private fun StringBuilder.appendTopUnresolved(title: String, generated: Boolean) {
    val groups =
      sites
        .filter { !it.target.resolved && it.generated == generated }
        .groupBy { "${it.site.name.lowercase()} ${it.text}" }
        .entries
        .sortedWith(compareBy({ -it.value.size }, { it.key }))
    appendLine("== top unresolved, $title (${groups.sumOf { it.value.size }} sites) ==")
    for ((key, group) in groups.take(TOP_UNRESOLVED)) {
      val diagnostics = group.map { it.diagnostic ?: "none" }.distinct().sorted().joinToString(",")
      appendLine("%6d  %s  [%s]".format(Locale.ROOT, group.size, key, diagnostics))
      for (site in group.take(EXAMPLES_PER_GROUP)) {
        appendLine("          ${site.path}:${site.line}:${site.column}")
      }
    }
    appendLine()
  }

  private fun List<CallSite>.handWrittenCallLike() = filter { it.site.callLike && !it.generated }

  private fun CallSite.inModule(module: String?) = module == null || this.module == module

  private fun ratio(group: List<CallSite>) = Ratio(group.size, group.count { it.target.resolved })

  private fun row(label: String, vararg cells: String): String =
    "%-26s".format(Locale.ROOT, label) + cells.joinToString("") { "%10s".format(Locale.ROOT, it) }
}

data class Ratio(val total: Int, val resolved: Int) {
  val fraction: Double
    get() = if (total == 0) 1.0 else resolved.toDouble() / total

  fun percent(): String =
    if (total == 0) "-" else "%.2f".format(Locale.ROOT, 100.0 * resolved / total)
}
