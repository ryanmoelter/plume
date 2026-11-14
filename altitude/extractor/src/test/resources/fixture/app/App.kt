package fixture.app

import fixture.core.Draft
import fixture.core.Store
import fixture.core.rename
import fixture.missing.Absent

fun run(): Long {
  rename(Store(Draft("a")))
  val absent: Absent? = null
  return missingFunction(1) + java.util.concurrent.atomic.AtomicLong().get()
}
