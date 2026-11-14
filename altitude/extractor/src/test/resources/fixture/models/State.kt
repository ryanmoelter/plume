package fixture.models

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue

@Composable
fun Counter(start: Item, pressed: Item) {
  var count by remember { mutableStateOf(start) }
  val shown = count
  sink(shown)
  LaunchedEffect(Unit) { sink(count) }
  Clicker(onClick = { count = pressed })
}

@Composable
fun Clicker(onClick: () -> Unit) {
  onClick()
}

class Config(val seed: Item) {
  val derived: Item by lazy { seed }

  fun read(): Item = derived
}
