package fixture.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

fun lengths(names: Flow<String>): Flow<Int> = names.map { it.length }

fun firstName(names: List<String>): String = names.first()
