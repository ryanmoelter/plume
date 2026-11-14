package fixture.models

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class Repository(private val scope: CoroutineScope) {
  private val _state = MutableStateFlow(Item("initial"))
  val state: StateFlow<Item> = _state.asStateFlow()

  val names: StateFlow<String> =
    state.map { item -> item.name }.filter { it.isNotEmpty() }.stateIn(scope, SharingStarted.Eagerly, "")

  fun rename(renamed: Item) {
    _state.update { old -> merge(old, renamed) }
  }

  fun replace(replacement: Item) {
    _state.value = replacement
  }

  fun observe() {
    scope.launch { names.collect { collected -> sink(collected) } }
  }

  fun current(): Item = state.value
}

fun merge(previous: Item, next: Item): Item = next

class Sync(private val scope: CoroutineScope) {
  private val requests = MutableSharedFlow<Item>(extraBufferCapacity = 1)

  fun request(requested: Item) {
    requests.tryEmit(requested)
  }

  fun start() {
    scope.launch { requests.collect { handle(it) } }
  }

  private fun handle(handled: Item) {
    sink(handled)
  }
}
