package com.ryanmoelter.altitude.trace

import com.ryanmoelter.altitude.facts.FlowFact
import java.util.PriorityQueue

/** The tracer's cap on a counted number of equal-cost paths. */
const val PATH_COUNT_CAP = 1_000_000L

/**
 * A location and the calls a value path is inside of there: a path that enters a function through
 * one call may not leave it through another.
 * [projected]: the call at which the path stepped from a container into this slot, if it did.
 * [filled]: the call at which the path wrote into this slot, if it did.
 * [held]: what the value is inside of, innermost last, as [Program.held] tracks it.
 */
data class ValueState(
  val location: String,
  val calls: List<String>,
  val projected: String? = null,
  val filled: String? = null,
  val held: List<String> = emptyList(),
)

/**
 * Bounds what a search tells apart at one location by [ValueState.held]. A value put into many
 * containers that all flow through one shared function would otherwise copy everything after that
 * function once per container. Past [limit] a state holds nothing, as if no container were known.
 */
private class HeldLimit(private val limit: Int = HELD_LIMIT) {
  private val seen = HashMap<String, HashSet<List<String>>>()

  fun admit(state: ValueState): ValueState {
    if (state.held.isEmpty()) return state
    val stacks = seen.getOrPut(state.location) { HashSet() }
    if (state.held in stacks) return state
    if (stacks.size >= limit) return state.copy(held = emptyList())
    stacks += state.held
    return state
  }
}

private const val HELD_LIMIT = 4

/** [rank] is the order in which the search first reached [state]. */
private data class Queued(val cost: PathCost, val rank: Int, val state: ValueState) : Comparable<Queued> {
  override fun compareTo(other: Queued): Int = cost.compareTo(other.cost).let { if (it != 0) it else rank.compareTo(other.rank) }
}

/** What a value search ends on. */
sealed interface ValueGoal {
  /** Stop at the first settled state at one of [locations], as `trace --value` does. */
  class Locations(val locations: Set<String>) : ValueGoal

  /** Settle every reachable state. */
  data object Everything : ValueGoal
}

/**
 * The search of `trace --value`: cheapest first, and among equal costs the state reached first.
 * Edges are visited in sorted order and nothing iterates a hash table, so the result is the same on
 * every run. [stop] names locations the search settles but does not leave.
 */
class ValueSearch(private val program: Program, private val budget: Int) {
  class Run internal constructor(val start: Set<String>) {
    val best = HashMap<ValueState, PathCost>()
    val paths = HashMap<ValueState, Long>()
    val via = HashMap<ValueState, Pair<ValueState, FlowFact>>()

    /** In the order the search settled them. */
    val settled = LinkedHashSet<ValueState>()

    /** The goal state, or with an exhausted budget the cheapest goal state reached so far. */
    var end: ValueState? = null
      internal set

    var exhausted = false
      internal set

    /** The states from a start state to [state], both included. */
    fun statesTo(state: ValueState): List<ValueState> = generateSequence(state) { via[it]?.first }.toList().asReversed()

    fun hopsTo(state: ValueState): List<FlowFact> {
      val hops = ArrayList<FlowFact>()
      var current = state
      while (true) {
        val (previous, edge) = via[current] ?: break
        hops += edge
        current = previous
      }
      return hops.asReversed()
    }
  }

  /**
   * [allow] prunes states known not to reach the goal. Leaving them out changes no path, since the
   * order among the states kept is the same.
   */
  fun run(start: Set<String>, goal: ValueGoal, stop: (String) -> Boolean = { false }, allow: ((ValueState) -> Boolean)? = null): Run {
    val run = Run(start)
    val goalLocations = (goal as? ValueGoal.Locations)?.locations
    val best = run.best
    val paths = run.paths
    val via = run.via
    val settled = run.settled
    val order = HashMap<ValueState, Int>()
    val queue = PriorityQueue<Queued>()
    for (location in start.sorted()) {
      val state = ValueState(location, emptyList())
      order[state] = order.size
      best[state] = PathCost.ZERO
      paths[state] = 1
      queue += Queued(PathCost.ZERO, order.getValue(state), state)
    }
    var end: ValueState? = null
    var steps = 0
    var reachedAtGoal: ValueState? = null
    val heldLimit = HeldLimit()
    search@ while (queue.isNotEmpty()) {
      val (cost, _, current) = queue.poll()
      if (cost != best[current] || !settled.add(current)) continue
      if (goalLocations != null && current.location in goalLocations) {
        end = current
        break
      }
      if (current.location !in start && stop(current.location)) continue
      for (edge in program.valueEdges[current.location].orEmpty()) {
        if (++steps > budget) break@search
        val target = program.next(current, edge)?.let(heldLimit::admit) ?: continue
        if (target in settled || allow?.invoke(target) == false) continue
        val next = cost + program.hopCost(edge, current.projected, current.held)
        val known = best[target]
        val comparison = if (known == null) -1 else next.compareTo(known)
        if (comparison < 0) {
          val rank = order.getOrPut(target) { order.size }
          best[target] = next
          paths[target] = paths.getValue(current)
          via[target] = current to edge
          queue += Queued(next, rank, target)
          if (goalLocations != null && edge.to in goalLocations) {
            val held = reachedAtGoal
            if (held == null || next < best.getValue(held)) reachedAtGoal = target
          }
        } else if (comparison == 0) {
          paths[target] = minOf(paths.getValue(target) + paths.getValue(current), PATH_COUNT_CAP)
        }
      }
    }
    run.exhausted = end == null && steps > budget
    run.end = if (run.exhausted) reachedAtGoal else end
    return run
  }
}
